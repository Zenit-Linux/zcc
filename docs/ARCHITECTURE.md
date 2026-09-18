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
pluginu w C: `examples/plugins/no_tabs_lint.c`. Gdy powstanie AST (etap 2),
dojdzie analogiczny `zcc_plugin_check_ast` obok istniejącego
`zcc_plugin_check_tokens`.

## 18. Obsługa standardów C99–C23

Lexer/parser mają tryb sterowany przez `-std=`:
- cechy językowe są tagowane min. wersją standardu (np. `_Generic` od C11,
  `typeof` od C23, digit separators od C23),
  parser odrzuca/akceptuje na podstawie configu.
- jeden AST dla wszystkich wersji, różnice to głównie: dostępność
  konstrukcji w parserze + różne domyślne makra predefiniowane
  (`__STDC_VERSION__` itd.) w preprocesorze.
