# Roadmap

## Etap 1 — Szkielet i CLI (teraz)
- [x] `zcc.nimble`, struktura katalogów
- [x] `src/main.nim` — parsowanie argumentów w stylu gcc
- [ ] `src/options.nim` — model configu (std, linkowanie, optymalizacje)
- [ ] Lexer C: literały, identyfikatory, słowa kluczowe (wg `-std=`)
- [ ] Testy: `tests/c/` z minimalnymi plikami `.c` (hello world, arytmetyka)

## Etap 2 — Front-end
- [ ] Preprocesor (`#include`, `#define`, `#if/#ifdef`, makra z argumentami)
- [ ] Parser: deklaracje, typy, wyrażenia, instrukcje sterujące
- [ ] AST + pretty-printer (do debugowania)
- [ ] Sema: sprawdzanie typów, scoping, podstawowa diagnostyka błędów
      z dobrymi komunikatami (to nasza przewaga nad gcc)

## Etap 3 — Codegen (MVP)
- [ ] Bindingi do LLVM z Nima (albo istniejący pakiet `llvm` z Nimble)
- [ ] Emisja IR → LLVM IR dla podzbioru C (funkcje, pętle, wskaźniki,
      struktury)
- [ ] Linker driver: statyczne linkowanie domyślne + `-dynamic`
- [ ] **Milestone**: zcc kompiluje i linkuje "hello world" do działającego
      binarnego pliku

## Etap 4 — Integracja z Nim compiler
- [ ] Test: zbudować prosty projekt Nim (`nim c`) przez zcc jako backend
      (Faza A z ARCHITECTURE.md — udawanie gcc)
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
- [ ] Podpiąć diagnostics.nim też w przyszłym parserze/sema (na razie
      tylko lexer z niej korzysta)
- [x] `src/depgen.nim`: `-MM`/`-MMD` (płytki skan `#include`)
- [ ] Podpiąć depgen pod prawdziwy preprocesor, gdy powstanie (etap 2)
      — obecny skan nie rozumie `#ifdef`/`#if`, więc może dawać
      fałszywe zależności
- [x] `src/cache.nim`: klucz = hash(źródło+flagi), `--cache-stats/--cache-clear`
- [ ] Realne spięcie cache z codegenem (na razie tylko HIT/MISS w logu
      `--verbose` — nie ma jeszcze czego cache'ować, bo brak codegenu)
- [x] `src/parallel.nim`: proces-poziomowy driver `-j`
- [ ] Realne odpalanie jobów z main.nim (na razie tylko plan w logu
      `--verbose` — czeka na `-c` które faktycznie coś produkuje)
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
- [ ] Realne odpalenie linkera i przechwycenie jego stderr (dziś:
      `analyzeLinkerFailure` gotowe, ale nic jeszcze nie generuje
      obiektów do linkowania - czeka na codegen)
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
- [ ] `zcc_plugin_check_ast` (hak semantyczny) - czeka na AST z etapu 2
- [ ] Testy jednostkowe preprocesora (macierz przypadków: makra zagnieżdżone,
      `#if` z wyrażeniami złożonymi, `##`/`#` na granicach argumentów)

## Etap 6 — Optymalizacje i wydajność
- [ ] Poziomy `-O0..-O3`, `-Os`
- [ ] Profilowanie: zcc vs gcc/clang na kodzie generowanym przez Nima
- [ ] LTO

## Etap 7 (opcjonalny, daleko) — własny backend
- [ ] Rozważenie zejścia z LLVM na własny generator kodu maszynowego,
      jeśli cele rozmiaru/szybkości builda tego wymagają dla Zenit Linux
