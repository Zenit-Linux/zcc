# Roadmap

## Etap 1 — Szkielet i CLI (teraz)
- [x] `zcc.nimble`, struktura katalogów
- [x] `src/main.nim` — parsowanie argumentów w stylu gcc (własny skaner
      argv zamiast `std/parseopt` — `parseopt` rozbijał jednoznakowe
      flagi z doklejoną wartością, np. `-std=c17`/`-Ipath`/`-Dfoo=1`/
      `-O2`, na osobne litery i cicho je gubił; to była realna, ukryta
      wada uderzająca dokładnie w zgodność CLI z gcc, na której opiera
      się Faza A integracji z Nimem — patrz ARCHITECTURE.md §1)
- [x] `src/options.nim` — model configu (std, linkowanie, optymalizacje;
      rozrósł się mocno w etapach 5b/5c o hardening/target/cache/jobs/PCH)
- [x] Lexer C: literały, identyfikatory, słowa kluczowe (wg `-std=`) —
      `src/lexer/lexer.nim`, pokryty testami w `tests/run_tests.nim`
- [x] Testy: `tests/c/` z minimalnymi plikami `.c` (hello world w
      `hello.c`; realny plik regresyjny na parser w `parser_smoke.c`)
- [x] Kompatybilność z Nim 1.6+ (nie tylko 2.0+): naprawione kilka
      miejsc, które kompilowały się tylko na Nim 2.x (jednoliniowe
      `if/else`-wyrażenia bez nawiasów, niejednoznaczne przeciążenie
      `countProcessors` z `osproc`/`cpuinfo`, `std/envvars` zamiast
      `std/os`, kolizja nazwy parametru template z etykietą pola w
      konstruktorze obiektu w `pp_lexer.nim` — ta ostatnia to subtelna
      pułapka higieny makr/templates w Nim, warto o niej pamiętać przy
      pisaniu kolejnych `template`-ów w tym projekcie)
- [x] Dwa realne bugi w parserze/lexerze z etapu 2, znalezione dopiero
      przy pisaniu end-to-end testów codegenu (etap 3) - zbyt subtelne,
      żeby wyłapać je bez faktycznego uruchamiania skompilowanego kodu:
      - `parser.nim`/`parseDeclaratorChain`: `char *f(int)` parsowało się
        jako "wskaźnik do funkcji" zamiast "funkcja zwracająca wskaźnik"
        (odwrócona kolejność składania wskaźnika prefiksowego z sufiksem
        funkcyjnym/tablicowym direct-declaratora - bardzo częsty idiom w
        C, np. `char *strcpy(...)`, więc ten bug blokował ogromną część
        typowego kodu). Naprawione, z obszernym komentarzem przy funkcji
        tłumaczącym poprawną regułę składania, żeby nie wrócił.
      - `lexer.nim`/`lexNumber`: literały szesnastkowe/binarne (`0x0F`,
        `0b101`) lexowały się jako `0` + osobny identyfikator (`x0F`),
        bo skanowanie liczby zatrzymywało się na pierwszej niecyfrze.
        Naprawione, przy okazji dodano prostą notację wykładniczą
        (`1e10`, `1.5e-3`), której wcześniej też brakowało.

## Etap 2 — Front-end
- [x] Parser: deklaracje, typy, wyrażenia, instrukcje sterujące
      (`src/parser/parser.nim` — recursive-descent, deklaratory budowane
      jako łańcuch domknięć, żeby poprawnie obsłużyć "spiralę" C:
      wskaźniki do funkcji, wskaźniki do tablic itd.)
- [x] AST + pretty-printer (do debugowania) — `src/parser/ast.nim`,
      `src/parser/printer.nim`, podpięte pod `--dump-ast`
- [x] Sema: scoping (zmienne/funkcje/typedeffy/tagi/stałe enuma),
      redefinicje, nieznane identyfikatory z sugestią "czy chodziło o..."
      (odległość Levenshteina), break/continue/case poza kontekstem,
      podstawowa kontrola liczby argumentów wywołania — `src/sema/sema.nim`,
      podpięte pod `-fsyntax-only`
- [x] Odzyskiwanie po błędach składni (panic-mode: synchronizacja do `;`/`}`)
      — wiele diagnostyk w jednym przebiegu zamiast przerwania na pierwszym
      błędzie
- [ ] Pełna kontrola typów wyrażeń (konwersje niejawne, promocje
      arytmetyczne C) — odłożone do etapu bliżej codegenu (patrz komentarz
      na górze `sema.nim`), żeby nie zgadywać reguł bez modelu `sizeof`/ABI
- [ ] Walidacja nazw pól przy `.`/`->` (wymaga w pełni rozwiązanych typów
      struct przez typedeffy)
- [ ] Scalanie wielokrotnych deklaracji tego samego tagu struct/union/enum
      (dziś: każde wystąpienie bez ciała tworzy osobny "stub" typu)
- [ ] Walidacja etykiet `goto` (wymaga dwuprzebiegowego zbierania etykiet
      funkcji)
- [ ] Literały złożone C99 `(Type){...}`, `_Generic` (C11), atrybuty
      `[[...]]` i `_BitInt(N)` (C23), stary styl K&R deklaracji parametrów
- [x] Testy: `tests/run_tests.nim` (lexer, preprocesor, parser, sema —
      w tym regresja na "spiralnych" deklaratorach i odzyskiwaniu po
      błędach), podpięte pod `nimble test`

## Etap 3 — Codegen (MVP)
- [x] Backend x86-64 (SysV ABI, Linux) generujący bezpośrednio asembler
      AT&T (`src/codegen/codegen.nim`), składany przez `as` i linkowany
      przez `ld` (binutils) - **NIE** bindingi LLVM ani nakładka na gcc/
      clang jako "driver". Decyzja świadoma: bindingi LLVM z Nima wymagają
      ciężkiej zależności (libLLVM + nagłówki), której nie było w tym
      środowisku; bezpośrednia emisja asemblera jest w pełni wystarczająca
      dla "MVP" i utrzymuje zero zależności zewnętrznych poza samym
      binutils, co i tak jest wymagane do zbudowania czegokolwiek na
      Linuksie. LLVM jako alternatywny/dodatkowy backend (dla lepszej
      optymalizacji) zostaje jako możliwość na później - patrz architektura
      w ARCHITECTURE.md, `codegen.nim` nie zakłada niczego, co by to
      wykluczało (generateModule -> tekst asemblera to czysta granica).
- [x] Emisja kodu dla: wyrażeń (arytmetyka, bitowe, porównania, ternary,
      przypisania w tym złożone, ++/--, wywołania w tym wariadyczne),
      instrukcji sterujących (if/while/do-while/for/switch/goto/break/
      continue/return), wskaźników i arytmetyki wskaźnikowej, tablic,
      struct/union (odczyt/zapis pól, kopiowanie przez `rep movsb`),
      enumów (stałe foldowane do literałów przed codegenem), zmiennych
      globalnych ze statycznymi inicjalizatorami (skalary, stringi,
      tablice/struktury z listami inicjalizującymi)
- [x] Linker driver (`src/linker.nim` + `src/target.nim`): lokalizacja
      crt1.o/crti.o/crtn.o i libc na hoście (glibc i musl, z fallbackiem
      między nimi), wywołanie `ld` ze statycznym linkowaniem domyślnie
      (zgodnie z README) + `-dynamic` na żądanie. Przy statycznym
      linkowaniu z glibc dochodzi `libgcc.a`+`libgcc_eh.a` (glibc.a
      odwołuje się do `_Unwind_Resume` i podobnych nawet w programach,
      które same w sobie ich nie używają - patrz komentarz przy
      `findLibgcc`/`findLibgccEh` w target.nim - to realny, dość zaskakujący
      szczegół, na który trafiono empirycznie przy pierwszym udanym
      statycznym linkowaniu)
- [x] **Milestone osiągnięty**: zcc kompiluje i linkuje "hello world" (z
      prawdziwym `printf` przez zewnętrzne `extern` bez potrzeby
      parsowania `<stdio.h>`) do działającego binarnego pliku ELF -
      zweryfikowane end-to-end (kompilacja -> as -> ld -> uruchomienie ->
      sprawdzenie stdout/exit code) w `tests/run_tests.nim`
- [x] **Float/double**: pełne wsparcie SysV ABI (rejestry XMM0-7,
      niezależny licznik od rejestrów całkowitych - klasyfikacja
      argumentów/parametrów w `classifyArgTypes`, dzielona między
      wywołania i definicje funkcji, żeby obie strony się zgadzały).
      Model wewnętrzny: wszystko liczone jako `double` w `%xmm0`/`%xmm1`,
      `float` zawężane tylko na granicy pamięci (load/store) przez
      cvtss2sd/cvtsd2ss - upraszcza rdzeń arytmetyki kosztem odrobiny
      precyzji dla czystych obliczeń na `float` (udokumentowane w
      nagłówku `codegen.nim`). Obsługuje: arytmetykę, porównania, cast
      int<->float, przypisania (w tym złożone `+=` itd.), pętle/warunki
      (`if`/`while`/`for`/`?:`/`&&`/`||` poprawnie testują wartości
      zmiennoprzecinkowe przez `ensureRaxBool`), globalne inicjalizatory
      stałe, przeplatane wywołania wariadyczne (`printf("%d %f", i, d)`)
      z poprawnym wyrównaniem stosu nawet przy przepełnieniu rejestrów
      int LUB float (algorytm dwuetapowy: odczyt-przez-offset, potem
      kompakcja argumentów stosowych - patrz komentarz przy
      `genArgsCommon`). Zweryfikowane end-to-end w `tests/run_tests.nim`
      (9 dodatkowych testów, w tym dot product na `struct` z polami
      `double` i wywołanie z 7 argumentami int + 1 double).
- [ ] Świadome ograniczenia tej iteracji (zgłaszane jako czytelny błąd
      kompilacji, NIE ciche zepsucie kodu - patrz nagłówek komentarza w
      `codegen.nim`):
      - struct/union nie mogą być przekazywane ani zwracane przez wartość
        w wywołaniach funkcji (zmienne/wskaźniki - jak najbardziej)
      - `-shared` (biblioteki współdzielone) nieobsługiwane - wymaga PIC
        i innych obiektów startowych (Scrt1.o)
      - tylko target x86_64-linux w tej iteracji (arm64/riscv64 z
        target.nim rozpoznawane składniowo we fladze `--target=`, ale
        codegen jeszcze nie generuje dla nich kodu)
      - cache builda (`src/cache.nim`) i równoległość (`src/parallel.nim`)
        są podpięte pod `-c`/link (patrz main.nim), ale parallel.nim samo
        w sobie nie jest jeszcze użyte przez główny pipeline wielu plików
        (kompilacja wielu `.c` na raz jest dziś sekwencyjna) - TODO
- [x] Dwa kolejne realne bugi znalezione dopiero przy pisaniu testów
      end-to-end dla float/double (ten sam wzorzec co bugi z etapu 2/3 -
      zbyt subtelne bez faktycznego uruchamiania skompilowanego kodu):
      - **`layout.nim`/`resolveTypedef` używany selektywnie**: kod, który
        iterował `ty.fields`/`ty.enumerators` BEZPOŚREDNIO (zamiast przez
        `fieldOffset`/`fieldType`, które już poprawnie rozwiązują
        niekompletne "kikuty" struct/union) po cichu widział PUSTĄ listę
        pól dla każdej zmiennej zadeklarowanej jako `struct Foo x = {...}`
        (bez ponownego podania ciała `{ ... }` przy TEJ deklaracji) -
        inicjalizator struktury z polami po prostu się nie wykonywał,
        zero błędu kompilacji. Naprawione dodaniem `resolvedFields()` w
        `layout.nim` i użyciem go wszędzie, gdzie kod iteruje pola wprost
        (`genLocalInit`, `emitStaticInit`).
      - **`cache.nim`/`computeKey` nie uwzględniał tożsamości samego
        kompilatora** - klucz cache liczony był tylko z treści źródła +
        flag, więc przebudowanie zcc (dokładnie to, co dzieje się cały
        czas w trakcie jego własnego rozwoju) NIE unieważniało starych
        wpisów: `-c`/link po naprawieniu buga w kompilatorze dalej cicho
        zwracały obiekty skompilowane STARĄ, wadliwą wersją. Naprawione
        przez dopisanie odcisku bieżącego pliku wykonywalnego zcc (mtime
        + rozmiar) do klucza - patrz `compilerFingerprint()`. To był
        najbardziej mylący bug w tej sesji: poprawka w kodzie wyglądała
        na nieskuteczną, dopóki nie sprawdzono `--verbose` i nie
        zobaczono `cache HIT` na teście, który miał wymusić MISS.

## Etap 4 — Integracja z Nim compiler
- [ ] Test: zbudować prosty projekt Nim (`nim c`) przez zcc jako backend
      (Faza A z ARCHITECTURE.md — udawanie gcc)
      - **Pierwsza próba podjęta, zablokowana na wejściu**: `nim c
        --compileOnly` wygenerował poprawny `.c` (`@mhello.nim.c`), ale
        już preprocesor zcc odbija się o `#include "nimbase.h"` ->
        `<limits.h>` (i dalej `<string.h>` itd.) - prawdziwe nagłówki
        systemowe glibc, których zcc nie ma w ścieżce wyszukiwania i,
        nawet gdyby miał, prawdopodobnie by ich nie sparsował (masowo
        używają rozszerzeń GNU - `__attribute__`, `__extension__`,
        zagnieżdżone makra warunkowe, `_Generic` itd. - żadne z tego nie
        jest jeszcze obsługiwane). To NIE jest problem możliwy do
        naprawienia punktowo - wymaga albo (a) własnego, minimalnego
        zestawu nagłówków libc kompatybilnego z tym, co generuje
        `nim c` (realistycznie duży, wieloetapowy projekt), albo
        (b) rozszerzenia preprocesora/parsera o brakujące rozszerzenia
        GNU NA TYLE, żeby realne nagłówki glibc/musl się sparsowały.
        Uczciwie: to wciąż daleko poza zasięgiem obecnego MVP - zostaje
        jako właściwy cel etapu 4, nie coś już odhaczone.
- [ ] Zestaw testów regresyjnych na realnych paczkach Nimble
- [ ] (opcjonalnie, później) PR/fork z natywnym profilem `zcc` w
      `extccomp.nim`

## Etap 5 — Pełne pokrycie C99–C23
- [ ] C99: VLA, designated initializers, `//` komentarze, `_Bool`
- [ ] C11: `_Generic`, `_Static_assert`, `_Atomic`, anonimowe struct/union
- [ ] C17: (głównie porządki/errata względem C11, bez nowych features)
- [ ] C23: `typeof`/`typeof_unqual`, `_BitInt(N)`, `nullptr`, `constexpr`,
      atrybuty `[[...]]`, digit separators, `#embed`
- [ ] Zgodność z realnymi test suite'ami (np. fragmenty GCC torture tests,
      gdzie licencja na to pozwala — do weryfikacji)

## Etap 5b — Hardening, cross-compilation, tooling, diagnostyka, cache
(dodane po pierwszej iteracji szkieletu — patrz docs/ARCHITECTURE.md §4-10)

- [x] `src/options.nim`: pola na hardening/target/depMode/jobs/cache/PCH
- [x] `src/hardening.nim`: `hardOff/hardDefault/hardMax`, rozwiązanie
      konfliktu `-static` + PIE (musl vs glibc)
- [x] `src/target.nim`: parsowanie target triple, host = musl domyślnie
- [x] `src/diagnostics.nim`: diagnostyka z podkreśleniem/sugestią,
      podpięta w lexerze (nieznane znaki)
- [x] Podpiąć diagnostics.nim też w parserze/sema (etap 2 — zrobione:
      `src/parser/parser.nim` i `src/sema/sema.nim` obie budują
      `Diagnostic` przez `errAt`/`warnAt`, ten sam format co lexer)
- [x] `src/depgen.nim`: `-MM`/`-MMD` (płytki skan `#include`)
- [ ] Podpiąć depgen pod prawdziwy preprocesor, gdy powstanie (etap 2)
      — obecny skan nie rozumie `#ifdef`/`#if`, więc może dawać
      fałszywe zależności
- [x] `src/cache.nim`: klucz = hash(źródło+flagi), `--cache-stats/--cache-clear`
- [x] Realne spięcie cache z codegenem (`main.nim`: `-c`/link sprawdzają
      `cache.lookup` przed kompilacją i wołają `cache.store` po sukcesie -
      patrz etap 3 wyżej, gdzie codegen faktycznie zaczął coś produkować)
- [x] `src/parallel.nim`: proces-poziomowy driver `-j`
- [ ] Realne odpalanie jobów RÓWNOLEGLE z main.nim (kompilacja wielu
      `.c` na raz jest dziś SEKWENCYJNA mimo że `-c` faktycznie coś
      produkuje od etapu 3 - `parallel.jobCount` istnieje, ale pipeline
      w main.nim jeszcze go nie używa do faktycznego zrównoleglenia)
- [x] `src/pch.nim`: zaprojektowany interfejs (bez realnej serializacji)
- [ ] Testy jednostkowe dla hardening.nim (macierz: arch × abi × link ×
      poziom hardeningu → oczekiwane flagi/ostrzeżenia)
- [ ] Realne wykrywanie hosta w `target.nim` (obecnie zgaduje po
      `defined(amd64)/defined(arm64)` z kompilacji zcc, nie po realnym
      `uname` systemu docelowego)

## Etap 5c — Preprocesor, sanitizery, LTO, reproducible, zcc.toml, plugin API
(dodane po drugiej iteracji — patrz docs/ARCHITECTURE.md §11-17)

- [x] `src/preprocessor/`: pełny driver (#define/#include/#if.../#pragma
      once), realnie odblokowuje `-E` i `--dump-tokens`
- [ ] Preprocesor: przenieść błędy z wyjątków na `diagnostics.nim`
      (dziś: surowy komunikat, lexer już robi to poprawnie - TODO doszlifować)
- [ ] Preprocesor: `__VA_OPT__` (C23), realne `#pragma` (dziś tylko `once`)
- [ ] Preprocesor: przejście z uproszczonego `activeSet` na pełny
      algorytm Prossera (hideset), jeśli testy zgodności wykryją rozjazd
      z gcc/clang na złożonych makrach
- [ ] Podpiąć `depgen.nim` pod prawdziwy preprocesor zamiast płytkiego
      skanu tekstowego (odziedziczone z poprzedniej iteracji, wciąż aktualne)
- [x] `src/sanitize.nim`: ASan/UBSan/TSan/MSan, wykryte niedozwolone
      kombinacje, ostrzeżenie przy `-static`
- [x] `src/linker.nim`: rozpoznawanie `undefined reference`/`undefined
      symbol`, sugestie `-lpthread`/`-lm`/`-ldl`/`-lrt`
- [x] Realne odpalenie linkera i przechwycenie jego stderr (`src/linker.nim`
      `linkExecutable`/`assembleFile` - `analyzeLinkerFailure` dostaje
      teraz prawdziwe wyjście `ld`, nie tylko przykładowe stringi z testów)
- [x] `src/lto.nim`: `--lto=thin|full`, flagi + nota o interakcji z cache
- [ ] Realny mechanizm cache na poziomie linkowania dla pełnego LTO
      (dziś: tylko `cacheKeySuffix` jako zalążek)
- [x] `src/reproducible.nim`: `--reproducible`, prefix-mapy, SOURCE_DATE_EPOCH
- [x] `src/projectconfig.nim`: `zcc.toml` (podzbiór TOML), przykład w
      `examples/zcc.toml.example`
- [ ] Pełniejszy TOML (zagnieżdżone tabele) jeśli configy urosną - dziś
      świadomie płaski/ograniczony parser bez zależności zewnętrznych
- [x] `src/plugins.nim`: ABI `.so` na poziomie tokenów, przykład w
      `examples/plugins/no_tabs_lint.c`
- [ ] `zcc_plugin_check_ast` (hak semantyczny) - AST z etapu 2 już
      istnieje (`src/parser/ast.nim`), plugin API wciąż działa tylko na
      poziomie tokenów (`runPluginOnTokens`) - podpięcie na AST to TODO
- [ ] Testy jednostkowe preprocesora (macierz przypadków: makra zagnieżdżone,
      `#if` z wyrażeniami złożonymi, `##`/`#` na granicach argumentów)

## Etap 6 — Optymalizacje i wydajność
- [ ] Poziomy `-O0..-O3`, `-Os`
- [ ] Profilowanie: zcc vs gcc/clang na kodzie generowanym przez Nima
- [ ] LTO

## Etap 7 (opcjonalny, daleko) — własny backend
- [ ] Rozważenie zejścia z LLVM na własny generator kodu maszynowego,
      jeśli cele rozmiaru/szybkości builda tego wymagają dla Zenit Linux
