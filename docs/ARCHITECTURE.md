# Architektura zcc

## 1. Integracja z Nim compiler

Nim's `extccomp.nim` zna zestaw "profili" kompilatorów (gcc, clang, vcc,
tcc, icl...) z szablonami flag. Mamy dwie drogi:

**Faza A (teraz — brak modyfikacji Nima):**
zcc udaje gcc na poziomie CLI. `nim.cfg` / `config.nims` projektu ustawia:
```
--cc:gcc
--gcc.exe:zcc
--gcc.linkerexe:zcc
```
Nim generuje wywołania w stylu gcc (`zcc -c foo.c -o foo.o -I... -D...`),
zcc musi je poprawnie sparsować. To wystarczy, żeby zacząć realnie testować
na prawdziwych projektach Nim bez czekania na PR do kompilatora Nim.

**Faza B (docelowo — natywny wpis):**
Dodajemy `zcc` jako pełnoprawny profil w `extccomp.nim` upstream (albo
we własnym forku Nima w Zenit Linux), z własnym zestawem flag
zoptymalizowanym pod zcc (np. `-fzcc-fast-goto`, dedykowane flagi LTO),
zamiast maskować się pod gcc.

## 2. Pipeline kompilatora

```
.c source
   │
   ▼
Preprocessor  (obsługa #include, #define, #if — etap 3)
   │
   ▼
Lexer          (src/lexer/)   — tokeny, wersja C-zależna (np. _BitInt od C23)
   │
   ▼
Parser         (src/parser/)  — AST, deklaracje, wyrażenia, statements
   │
   ▼
Sema           (analiza semantyczna, typowanie, sprawdzanie standardu)
   │
   ▼
IR             (prosta SSA-like reprezentacja pośrednia)
   │
   ▼
Codegen        (src/codegen/) — na start: emisja przez LLVM (llvm-nim
                bindings) zamiast pisania własnego backendu asemblera
                od zera; własny backend to opcja na dużo później)
   │
   ▼
Linker driver  (src/linker.nim) — domyślnie statyczne linkowanie
                (ld -static / self-contained), -dynamic dla .so
```

**Decyzja**: na start korzystamy z LLVM jako backendu kodu maszynowego
(via bindingi Nim->LLVM C API), zamiast pisać własny generator kodu
maszynowego x86_64/ARM64 od zera. To pozwala szybciej dojść do "zcc
kompiluje realny program C" i skupić się na froncie (parser C99-C23),
który jest unikalną wartością projektu. Własny backend to opcjonalny
etap 5+, jeśli LLVM okaże się za wolny/za ciężki jako zależność dla
Zenit Linux.

## 3. Statyczne linkowanie domyślnie

- Domyślny tryb: `zcc foo.c -o foo` → linker driver dodaje `-static`
  (lub odpowiednik dla libc używanego w Zenit Linux — do ustalenia:
  glibc statyczny bywa duży i ma ograniczenia z NSS/dlopen; alternatywa:
  musl jako domyślna libc dla zcc, z możliwością przełączenia).
- `-dynamic` / `--dyn-link` → normalne dynamiczne linkowanie (`.so`),
  potrzebne np. pod pluginy albo biblioteki systemowe wymagające dlopen.

## 4. Hardening domyślny (`src/hardening.nim`)

Poziomy: `hardOff` / `hardDefault` (domyślny) / `hardMax`.

- **default**: `-fstack-protector-strong`, `-D_FORTIFY_SOURCE=2`,
  `-fstack-clash-protection`, `-fPIE`.
- **max**: dodatkowo CFI sprzętowy zależny od architektury — Intel CET
  (`-fcf-protection=full`) na x86_64, ARM PAC/BTI
  (`-mbranch-protection=standard`) na aarch64.
- **Konflikt static+PIE**: pełny `-static` + PIE jest kruchy na glibc
  (wymaga `-static-pie`, historycznie niestabilnego w części toolchainów).
  Rozwiązanie: dla `abi=musl` pozwalamy na pełny `-static-pie` nawet przy
  `hardMax`; dla `abi=gnu` przy `-static` PIE jest świadomie wyłączany
  z jawnym ostrzeżeniem zamiast cichego wygenerowania potencjalnie
  niestabilnej binarki. Stąd też domyślne ABI hosta w `target.nim` to
  **musl**, nie glibc — spójne z "statyczne linkowanie domyślnie" jako
  fundamentalnym założeniem projektu.

## 5. Cross-compilation (`src/target.nim`)

Target triple w stylu LLVM (`<arch>-<os>-<abi>`), np. `aarch64-linux-musl`
dla SBC/ARM serwerów. Domyślnie target = host. LLVM jako backend
(patrz sekcja 2) przyjmuje triple natywnie, więc cross-compilation to
głównie kwestia: (a) poprawnego doboru triple dla LLVM, (b) dostępności
odpowiedniego sysroot/libc dla targetu — to drugie jeszcze nie
zaprojektowane, do zrobienia przy pierwszym realnym cross-buildzie.

## 6. Cache builda (`src/cache.nim`)

Cache na poziomie jednostki translacji, jak ccache, ale wbudowany.
Klucz = hash treści źródła + istotne flagi (`std`, `opt`, `target`,
`hardening`, `link`, `-I`, `-D`). Ważne dla integracji z Nim: `nim c`
generuje dużo małych plików `.c`, z których spora część się nie zmienia
między buildami tego samego projektu. Hash niekryptograficzny
(`std/hashes`) na start — wystarczający lokalnie, do rozważenia
blake3/xxhash przy większej skali.

## 7. Równoległość (`src/parallel.nim`)

Model proces-poziomowy (jak `make -j`/ninja), nie wątki w jednym procesie
zcc — self-invocation (`zcc -c plik.c ...`) per jednostka translacji,
z limitem współbieżności = liczba rdzeni (albo `-j N`). Unika komplikacji
GC/thread-safety wewnątrz kompilatora.

## 8. Prekompilowane nagłówki (`src/pch.nim`)

Zaprojektowany interfejs, implementacja czeka na gotowy parser/sema
(potrzebne, żeby było co serializować). Cel: nagłówki Nim-owego runtime
(`nimbase.h` i pochodne), powtarzalne w każdym generowanym `.c`, parsowane
raz zamiast setki razy per build.

## 9. Diagnostyka (`src/diagnostics.nim`)

Błędy w stylu clang/rustc: lokalizacja, linia źródłowa, podkreślenie
(`^~~~`), opcjonalna sugestia naprawy (`suggestion:`) i notatki
kontekstowe. To ma być realna, mierzalna przewaga nad domyślnym gcc,
które wciąż bywa lakoniczne (`error: expected ';' before ...`).
Zaimplementowane i podpięte już w lexerze (`lexer.nim` zbiera `diags`).

## 10. Generowanie zależności (`src/depgen.nim`)

`-MM` (reguły make na stdout, bez kompilacji) i `-MMD` (plik `.d` obok
wyjścia + normalna kompilacja) — potrzebne, bo build systemy (make,
ninja, i pośrednio sam Nim) oczekują tego interfejsu od kompilatora C.
Na tym etapie: płytki skan tekstowy `#include` (bez pełnego
preprocesora — patrz TODO w pliku), wystarczający do prostych
przypadków; ma zostać podpięty pod prawdziwe drzewo preprocesora
w etapie 2.

## 11. Preprocesor (`src/preprocessor/`)

**Jedyny realny bloker odblokowany w tej iteracji** - reszta modułów
(depgen, cache) była do tej pory rusztowaniem czekającym właśnie na to.

- `pp_lexer.nim` - tokenizer pp-tokenów, osobny od `src/lexer/lexer.nim`,
  bo preprocesor musi widzieć strukturę linii (dyrektywa `#` tylko jako
  pierwszy niebiały token w linii) i obsłużyć `\<newline>` continuation
  przed czymkolwiek innym.
- `macros.nim` - definicje makr (obiektowe/funkcyjne/wariadyczne),
  operatory `#` (stringify) i `##` (paste). Rekursja blokowana przez
  uproszczony mechanizm `activeSet` zamiast pełnego algorytmu Prossera
  (hideset per-token) - poprawne dla typowych przypadków, TODO przy
  pierwszych realnych rozbieżnościach wobec gcc/clang na złożonych makrach.
- `pp_expr.nim` - ewaluator wyrażeń stałych dla `#if`/`#elif`
  (arytmetyka int64, `defined`, `?:`, pełny zestaw operatorów C).
- `preprocessor.nim` - driver: `#define/#undef/#include/#if.../#pragma
  once/#error`, stos warunkowej kompilacji, rozwiązywanie `#include`
  (reużywa logiki podobnej do `depgen.resolveHeader`).

**Znane ograniczenia** (uczciwie, nie ukrywane): brak `__VA_OPT__` (C23),
brak realnego `#pragma` poza `once`, błędy zgłaszane jako wyjątki zamiast
przez `diagnostics.nim` (TODO - lexer już to robi poprawnie, preprocesor
jeszcze nie).

Preprocesor podłączony jest już do CLI: `-E` (czysty preprocesor) i
`--dump-tokens` (domyślnie preprocesuje przed tokenizacją; `--no-preprocess`
pozwala zobaczyć surowy lexing bez niego, do debugowania samego lexera).

## 12. Sanitizery (`src/sanitize.nim`)

Pierwszorzędna, nie dodana na siłę opcja - skoro backend to LLVM,
ASan/UBSan/TSan/MSan to głównie przekazanie `-fsanitize=...` dalej.
Wykrywane i blokowane niedozwolone kombinacje (ASan+TSan, TSan+MSan).
Ostrzeżenie przy `-static` (runtime sanitizerów tradycyjnie jest `.so`).

## 13. Recovery błędów linkera (`src/linker.nim`)

Parsuje `undefined reference to` (GNU ld) i `undefined symbol:` (LLD) bez
zależności od `std/re`/libpcre (świadomie - kompilator dystrybucji nie
powinien ciągnąć zależności systemowej tylko po to, żeby sparsować
dwa stałe formaty tekstu). Mała, świadomie nie-wyczerpująca tablica
`symbol -> biblioteka` (pthread, m, dl, rt) rozbudowywana na bazie
realnych zgłoszeń, nie prób pokrycia całej przestrzeni symboli libc.

## 14. LTO (`src/lto.nim`)

`--lto=thin` (zalecany default przy wyższych `-O`) vs `--lto=full`.
Ważna decyzja architektoniczna: **pełny LTO psuje trafność zwykłego
cache per-TU** z `cache.nim`, bo wynik zależy od całego grafu linkowania,
nie pojedynczego pliku - `cacheKeySuffix` w wyniku to zalążek pod
przyszły, osobny mechanizm cache na poziomie linkowania (nieopisany
jeszcze w pełni, TODO).

## 15. Reprodukowalne buildy (`src/reproducible.nim`)

`--reproducible`: `-ffile-prefix-map`/`-fdebug-prefix-map` (ścieżki
względne zamiast absolutnych), `SOURCE_DATE_EPOCH` (reproducible-builds.org),
`-frandom-seed` deterministyczny per plik, `ar D` (deterministyczne
archiwa zamiast zależnych od mtime). Istotne dla Zenit Linux jako
dystrybucji - to praktycznie dziś wymóg, nie nice-to-have.

## 16. Konfiguracja projektu - `zcc.toml` (`src/projectconfig.nim`)

**Nie pełny parser TOML** - świadomie ograniczony podzbiór (płaskie
sekcje, stringi/liczby/bool/tablice stringów, komentarze `#|), bo Nim
nie ma TOML w stdlib, a ciągnięcie zewnętrznej zależności przez nimble
nie pasuje do "kompilator dystrybucji ma być samowystarczalny". Wczytywany
automatycznie z najbliższego `zcc.toml` w górę drzewa katalogów jako
**baza domyślnych wartości** - flagi CLI zawsze nadpisują. Przykład:
`examples/zcc.toml.example`.

## 17. Plugin API (`src/plugins.nim`)

**Uczciwie**: pełny plugin API (hak na AST/typy) wymaga sema, którego
jeszcze nie ma. To co działa DZIŚ to hak na poziomie strumienia tokenów
z lexera - wystarczające dla reguł stylu (zakaz tabów, długość linii,
zakazane identyfikatory), nie dla analiz semantycznych. ABI: `.so` z
funkcjami C (`{.cdecl.}`), ten sam model co pluginy gcc/clang - niezależny
od tego, w jakim języku plugin jest napisany. Przykład działającego
pluginu w C: `examples/plugins/no_tabs_lint.c`. AST istnieje już od
etapu 2 (`src/parser/ast.nim`), ale hak `zcc_plugin_check_ast` na nim
jeszcze nie powstał - dziś pluginy widzą wyłącznie strumień tokenów
przez `zcc_plugin_check_tokens` (patrz `runPluginOnTokens` w `plugins.nim`).

## 18. Obsługa standardów C99–C23

Lexer/parser mają tryb sterowany przez `-std=`:
- cechy językowe są tagowane min. wersją standardu (np. `_Generic` od C11,
  `typeof` od C23, digit separators od C23),
  parser odrzuca/akceptuje na podstawie configu.
- jeden AST dla wszystkich wersji, różnice to głównie: dostępność
  konstrukcji w parserze + różne domyślne makra predefiniowane
  (`__STDC_VERSION__` itd.) w preprocesorze.

**Stan dziś (uczciwie)**: `-std=` steruje lexerem/preprocesorem
(makra predefiniowane, `//` komentarze itd. — patrz `tokens.nim`), ale
parser (`src/parser/parser.nim`) **jeszcze nie odrzuca** konstrukcji
spoza wybranego standardu - akceptuje liberalnie nadzbiór (np. `nullptr`
czy `bool` jako słowo kluczowe działają nawet z `-std=c99`). Twarde
bramkowanie cech językowych wg `CStd` to TODO na etap 5, gdy będzie
komplet testów zgodności per-standard do zweryfikowania, że bramkowanie
niczego nie psuje.

## 19. Parser, AST i sema (`src/parser/`, `src/sema/`)

Etap 2 z ROADMAP.md. Trzy moduły, jeden kierunek przepływu danych:
tokeny z lexera → `parser.parseTokens` → `ast.Node` (`TranslationUnit`)
→ `sema.runSema` → diagnostyki. `printer.dumpAst` to ślepy odczyt AST,
nie wpływa na resztę pipeline'u - czysto debugowe narzędzie za `--dump-ast`.

**AST (`ast.nim`)**: świadomie "płaski" `Node` - jeden `ref object` z
polami ogólnego przeznaczenia (`a`,`b`,`c`,`d`,`list`,`op`,`strVal`,`typ`)
zamiast osobnego typu wariantowego per `NodeKind`. Znaczenie pól opisane
w komentarzu przy każdej wartości `NodeKind`. Kompromis świadomy: mniej
boilerplate'u teraz, koszt płaci się czytelnością (trzeba znać konwencję)
- do rewizji, jeśli AST urośnie w etapie 5+ o pełne C99-C23.

**Parser (`parser.nim`)**: ręczny recursive-descent, zero zależności/
generatorów parserów. Dwa miejsca, gdzie C jest naprawdę nieprzyjemny do
parsowania, i jak je tu rozwiązano:
1. **Deklaratory "na spirali"** (`int (*p)[10]`, wskaźniki do funkcji,
   funkcje zwracające wskaźniki do funkcji...) - budowane jako łańcuch
   domknięć `proc(base: CType): CType {.closure.}`, składanych w
   kolejności zgodnej z gramatyką deklaratora (`parseDeclaratorChain`/
   `parseDirectDeclaratorChain`). To jest najbardziej "gęsty" fragment
   parsera - warto przeczytać komentarz na górze pliku przed edycją.
2. **Problem typedef** (`Foo * x;` - deklaracja czy mnożenie?) -
   parser trzyma stos zbiorów znanych nazw typedef (`typedefScopes`),
   aktualizowany na bieżąco w trakcie parsowania, zgodnie z tym, jak
   wymaga tego standard C (nierozwiązywalne wyłącznie w sema, po fakcie).

Odzyskiwanie po błędach: **bez wyjątków** w normalnym przepływie - błąd
składni zgłasza `Diagnostic` (ten sam `errAt`/`warnAt` co lexer) i
synchronizuje się do najbliższego `;`/`}`, żeby zgłosić więcej niż jeden
błąd na przebieg. To jest wprost ta "przewaga w diagnostyce nad gcc" z
README, tylko przeniesiona z lexera do parsera.

**Sema (`sema.nim`)**: scoping przez stos `Table[string, Sym]`, jeden
przebieg nad AST. Zakres dziś: redefinicje, nieznane identyfikatory
(z sugestią "czy chodziło o..." oparte o odległość Levenshteina - patrz
`suggestSimilar`), stałe enuma jako osobne symbole (`declareTag`),
break/continue/case poza kontekstem, kontrola liczby argumentów wywołania
względem znanego prototypu, ostrzeżenia o niezgodnym `return`. Celowo
**nie robi** pełnej kontroli typów wyrażeń (konwersje niejawne, promocje
arytmetyczne C) - to wymaga kompletnego modelu rozmiarów/ABI z `target.nim`,
którego jeszcze nie ma w tej formie; zgadywanie reguł bez tego dawałoby
fałszywe poczucie bezpieczeństwa gorsze niż brak kontroli.

**CLI**: `-fsyntax-only` (parsuj+sprawdź, nie generuj kodu) i `--dump-ast`
(jak wyżej + wypisz drzewo). `--no-sema` pozwala pominąć sema przy
debugowaniu samego parsera. Diagnostyki z parsera i sema są łączone i
deduplikowane (`dedupDiags` w `main.nim`) przed wypisaniem - obie warstwy
celowo powtarzają część kontroli (np. break/continue poza pętlą) dla
odporności, gdy AST trafi kiedyś do sema spoza tego pipeline'u (np.
plugin API, patrz §17), więc trzeba je scalić, żeby użytkownik nie
widział tego samego błędu dwa razy.

## 20. Codegen: x86-64, `as`/`ld` (`src/codegen/`, `src/linker.nim`, `src/target.nim`)

Etap 3 z ROADMAP.md - **milestone "hello world" osiągnięty**: `./zcc
program.c -o program && ./program` daje działający plik ELF, zweryfikowane
end-to-end (włącznie z prawdziwym `printf`) w `tests/run_tests.nim`.

**Decyzja architektoniczna**: bezpośrednia emisja asemblera x86-64 (AT&T),
złożenie przez `as` i linkowanie przez `ld` (oba z binutils) - **nie**
bindingi LLVM, **nie** nakładka na gcc/clang jako "driver". Powód: LLVM
jako zależność (libLLVM + nagłówki C++) jest ciężki i niedostępny w wielu
środowiskach (w tym tym, w którym pisany był ten kod), a cel etapu to
"MVP" - działający kompilator, nie najszybszy wygenerowany kod. Granica
`generateModule(unit) -> tekst asemblera` w `codegen.nim` jest na tyle
czysta, że LLVM (albo jakikolwiek inny backend) mógłby zostać dodany
później jako ALTERNATYWA, nie przepisanie.

**Model generacji (`codegen.nim`)** - uproszczony, ale rozmyślnie:
- **Brak alokacji rejestrów.** Każde wyrażenie liczone jest w %rax;
  wyrażenia binarne odkładają lewy operand przez prawdziwe `pushq`/`popq`
  CPU (klasyczna "stack machine"). Wolniejsze niż zoptymalizowany kod
  gcc, ale eliminuje całą klasę błędów alokatora rejestrów - właściwy
  kompromis dla MVP.
- **Zmienne lokalne = stałe sloty.** Każda zmienna lokalna (w tym
  zagnieżdżona w blokach) dostaje własny, na stałe przydzielony offset
  `-N(%rbp)` w ramce funkcji - bez odzyskiwania miejsca między sąsiednimi
  blokami. Marnuje trochę stosu, upraszcza dramatycznie codegen.
- **Wyrównanie stosu do 16 bajtów przy `call`** (wymóg SysV ABI - inaczej
  instrukcje SSE używane WEWNĄTRZ funkcji bibliotecznych jak `printf`
  segfaultują) pilnowane przez `ctx.pushDepth` - licznik odłożonych
  8-bajtowych wartości śledzony W CZASIE GENEROWANIA kodu (nie w
  runtime); jego parzystość mówi, czy %rsp jest aktualnie 16-wyrównany.
  Padding wstawiany selektywnie tuż przed `call`, gdy parzystość tego
  wymaga - patrz komentarz przy `genArgsCommon`.
- **Agregaty (struct/union/tablica) jako "wartość" = ich ADRES w %rax.**
  Nigdy nie są kopiowane do rejestru w całości. `genLoad` ładuje spod
  adresu (dereferencja) TYLKO dla typów skalarnych (`isScalarType` z
  `layout.nim`) - dla agregatów zostawia adres, co naturalnie realizuje
  rozpad tablicy do wskaźnika (array decay) bez żadnego specjalnego kodu.
- **`sizeof(wyrażenie)` bez efektów ubocznych** (C tego wymaga poza VLA,
  nieobsługiwanymi tutaj) realizowane sztuczką: `typeOfExprNoEmit`
  przekierowuje bufor wyjściowy na czas wywołania `genExpr`, odczytuje
  zwrócony typ, i odrzuca wygenerowany tekst - bezpieczne, bo żadna
  "prawdziwa" ewaluacja się nie dzieje w fazie codegenu (to tylko tekst),
  jedyne ryzyko (niebalansowanie `pushDepth`) nie występuje, bo `genExpr`
  zawsze sam bilansuje własne push/pop.

**Dwa przebiegi scalające AST przed właściwym codegenem** (obie w
`resolveAllTypedefs`/`foldEnumConstants`, wywoływane na początku
`generateModule`) - bez nich całe klasy poprawnego kodu C by nie działały:
1. **Scalanie typedefów I tagów struct/union/enum.** Parser tworzy NOWĄ,
   niezależną instancję `CType` przy KAŻDYM wystąpieniu `struct Foo`/
   `typedef`-nazwy w źródle (patrz `parser.nim`) - `struct Point p;` po
   wcześniejszym `struct Point { int x, y; };` gdzie indziej dostawałoby
   pusty, niekompletny typ bez pól, gdyby nic tego nie scaliło. Pole
   `CType.resolved` (jedno na oba przypadki: alias typedefu i niekompletny
   tag) jest wypełniane jednym przebiegiem po całym drzewie AST, a
   `layout.resolveTypedef` podąża za tym łańcuchem przy każdym
   `typeSizeOf`/`fieldOffset`/itd. Uproszczenie: jeden płaski, globalny
   zakres nazw (nie w pełni poszanowany zasięg bloków) - udokumentowane
   ograniczenie, jak przy podobnych uproszczeniach w sema.
2. **Foldowanie stałych enuma do literałów.** Zamiast przeciągać osobną
   tabelę symboli przez cały `layout.nim` (który m.in. liczy rozmiary
   tablic i etykiety `case` - obie rzeczy potrzebują znać wartości stałych
   enuma), `foldEnumConstants` podmienia w AST każdy `nkIdent` o nazwie
   znanej stałej enuma na `nkIntLit` z jej wartością, mutując węzeł w
   miejscu. Po tym przebiegu `case GREEN:` i `int arr[GREEN + 1]` działają
   bez żadnej specjalnej obsługi w reszcie codegenu - `evalConstInt`
   widzi już zwykłe liczby.

**`layout.nim`**: sizeof/alignof/offsety pól dla modelu LP64 (Linux
x86-64: char=1, short=2, int=4, long/long long/wskaźnik=8) + ewaluator
stałych wyrażeń całkowitych (`evalConstInt` - rozmiary tablic, wartości
enumeratorów, etykiety `case`, `_Static_assert`). Oba w jednym module
celowo: `sizeof(T)` użyte w stałej potrzebuje `typeSizeOf`, a
`typeSizeOf` dla tablic potrzebuje ewaluatora do policzenia rozmiaru z
wyrażenia - rozdzielenie ich na osobne moduły dałoby cykl importów.

**Linker driver (`linker.nim` + `target.nim`)**: `assembleFile`/
`linkExecutable` wołają `as`/`ld` bezpośrednio (nie przez gcc). Lokalizacja
crt1.o/crti.o/crtn.o i libc (`findCLibPaths`) próbuje najpierw ABI
docelowej (musl - patrz `hostTarget()`), a jeśli jej nie ma na hoście,
spada na glibc (i odwrotnie) - dzięki temu kompilacja działa "od ręki" na
zwykłym Ubuntu/Debianie (gdzie zwykle jest tylko glibc), mimo że docelowa
dystrybucja projektu (Zenit Linux) ma być na musl. Szczegół odkryty
empirycznie: **statyczne** linkowanie z glibc wymaga dołączenia
`libgcc.a` ORAZ `libgcc_eh.a` (glibc.a odwołuje się do `_Unwind_Resume` i
podobnych nawet w programach, które same w sobie nie używają wyjątków ani
C++) - `findLibgcc`/`findLibgccEh` lokalizują je pytając zainstalowane
`gcc` o ścieżkę (to nie jest "użycie gcc jako kompilatora", tylko
znalezienie gotowej biblioteki statycznej, podobnie jak zwykłe `-lc`);
musl nie ma tego problemu i nie potrzebuje tego kroku.

**Świadome ograniczenia tej iteracji** (zgłaszane jako czytelny błąd
kompilacji - nigdy ciche zepsucie kodu): struct/union nie mogą być
przekazywane/zwracane przez wartość w wywołaniach funkcji; `-shared`
nieobsługiwane (wymaga PIC); tylko target x86_64-linux generuje kod w
tej iteracji. Pełna lista w nagłówku komentarza `codegen.nim` i w
ROADMAP.md (etap 3).

**Float/double**: pełne wsparcie SysV ABI, dodane po pierwszej wersji
tego modułu. Model: WSZYSTKO liczone wewnętrznie jako `double` w
`%xmm0`/`%xmm1` (druga robocza wartość); `float` zawężane do/z double
TYLKO na granicy pamięci (load/store) przez `cvtss2sd`/`cvtsd2ss` -
upraszcza rdzeń arytmetyki do jednego zestawu instrukcji SSE2 kosztem
odrobiny precyzji/wydajności dla czystych obliczeń na `float`. Rejestry
całkowite (rdi..r9) i zmiennoprzecinkowe (xmm0-7) mają NIEZALEŻNE liczniki
przy przekazywaniu argumentów/parametrów wg SysV ABI - `classifyArgTypes`
implementuje tę klasyfikację RAZ i jest współdzielona między `genFunction`
(odczyt parametrów) i `genArgsCommon` (przekazywanie argumentów), bo obie
strony MUSZĄ się zgodzić (klasyfikacja zależy wyłącznie od typów w
sygnaturze). `genArgsCommon` obsługuje poprawnie nawet przepełnienie
JEDNEJ klasy rejestrów przy wciąż wolnych miejscach w drugiej (np. 7
argumentów int + 1 double - siódmy int ląduje na stosie, ale double wciąż
mieści się w xmm0) - wymaga to dwuetapowego schematu (odczyt-przez-offset
zamiast sekwencyjnego `pop`, potem kompakcja argumentów stosowych do
ciasnego regionu), bo zwykłe sekwencyjne zdejmowanie ze stosu nie radzi
sobie z przeplotem klas - szczegółowy komentarz przy `genArgsCommon`
tłumaczy dlaczego. `ensureRaxBool` normalizuje warunki (`if`/`while`/
`for`/`?:`/`&&`/`||`) do testu na `%rax` niezależnie od tego, czy
ostatnia obliczona wartość była w `%rax` czy `%xmm0`.

**Pułapka znaleziona przy pierwszym teście struktur z polami `double`**:
kod, który iterował `ty.fields` BEZPOŚREDNIO (pomijając `fieldOffset`/
`fieldType`, które poprawnie podążają za `.resolved` - patrz wyżej),
widział pustą listę pól dla każdego "kikuta" struct - inicjalizatory pól
po prostu się nie generowały, bez żadnego błędu kompilacji. `layout.nim`
eksportuje teraz `resolvedFields()` właśnie po to, żeby taki kod (
`genLocalInit`, `emitStaticInit`) miał jeden oczywisty, poprawny sposób
iterowania pól. Wniosek na przyszłość: KAŻDY nowy kod w `codegen.nim`,
który chce iterować `.fields`/`.enumerators` typu z AST, powinien pytać
"czy to może być kikut?" i użyć `resolvedFields()`, nie `.fields`
wprost - `fieldOffset`/`fieldType`/`typeSizeOf` już to robią poprawnie,
ale to nie jest wymuszone przez system typów Nim, więc łatwo o regresję.

## 21. Cache i tożsamość kompilatora (`src/cache.nim`)

Klucz cache (`computeKey`) musi zależeć nie tylko od treści źródła i
flag, ale też od TOŻSAMOŚCI SAMEGO KOMPILATORA - inaczej przebudowanie
zcc (co dzieje się bez przerwy w trakcie jego własnego rozwoju) nie
unieważnia starych wpisów, i `-c`/link zaczynają cicho zwracać obiekty
skompilowane poprzednią, potencjalnie wadliwą wersją zcc. Realny bug
znaleziony w tej sesji: poprawka błędu w codegenie (patrz §20) wyglądała
na nieskuteczną, dopóki `--verbose` nie ujawnił `cache HIT` na teście,
który powinien był wymusić rekompilację. `compilerFingerprint()` dolicza
teraz mtime+rozmiar bieżącego pliku wykonywalnego zcc (`getAppFilename()`)
do klucza - prosta, ale wystarczająca heurystyka (ten sam mechanizm,
którego domyślnie używa `ccache` do wykrywania zmiany kompilatora).
