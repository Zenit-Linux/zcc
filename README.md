# zcc — Zenit C Compiler

Kompilator C (C99–C23) napisany w **Nim**, będący domyślnym backendem C
dla dystrybucji **Zenit Linux** oraz — co ważne — dobrym, natywnym
backendem C dla samego **kompilatora Nim** (który i tak transpiluje do C
i potrzebuje zewnętrznego kompilatora, żeby zbudować binarkę).

## Dlaczego to ma sens

Nim domyślnie generuje `.c` i woła `gcc`/`clang`/`tcc` żeby je zbudować.
zcc ma być tą trzecią opcją, ale zoptymalizowaną pod kod generowany przez
`nim c` (mnóstwo małych funkcji, charakterystyczne wzorce alokacji,
goto-heavy control flow z systemu wyjątków Nima) — szybsza kompilacja tego
konkretnego stylu C niż ogólny gcc, plus lepsze błędy.

## Założenia

- **Standardy**: `-std=c99|c11|c17|c23` (domyślnie c17, jak nowoczesny gcc).
- **Linkowanie**: **statyczne domyślnie**. Dynamiczne wymaga `-dynamic`
  (alias `--dyn-link`).
- **Zgodność CLI z gcc** dla podzbioru flag, których używa Nim
  (`-c`, `-o`, `-I`, `-D`, `-l`, `-L`, `-O0..3`, `-g`, `-fPIC`, `-pthread`...)
  — dzięki temu można go podpiąć pod Nima bez modyfikowania samego Nima,
  przez `nim.cfg`:
  ```
  cc = gcc
  gcc.exe = zcc
  gcc.linkerexe = zcc
  ```
  Docelowo (etap dalszy): natywny wpis `zcc` w `compiler/extccomp.nim`
  Nima, żeby nie udawać gcc.
- **Napisany w Nim**: bootstrap trywialny, bo Nim już istnieje —
  nie trzeba etapu "stage0 w C". Kompilujemy zcc od razu przez `nim c`.

## Struktura

```
zcc.nimble
src/
  main.nim         # CLI, dispatch (driver)
  options.nim       # parsowanie flag, config kompilacji
  lexer/            # tokenizer C
  preprocessor/     # #include/#define/#if.../#pragma once
  parser/           # AST C + recursive-descent parser + pretty-printer
  sema/             # scoping, diagnostyka semantyczna (-fsyntax-only)
  codegen/          # backend x86-64 (asembler AT&T) -> as -> ld
  linker.nim        # wywołanie as/ld, lokalizacja crt/libc, diagnostyka linkera
  target.nim        # architektura/ABI docelowa, lokalizacja toolchaina hosta
docs/
  ARCHITECTURE.md
  ROADMAP.md
tests/
  c/                # przypadki testowe .c per standard (c99../c23)
  nim_integration/  # testy "zbuduj prawdziwy projekt Nim przez zcc"
```

## Build

```sh
nimble build          # -> ./zcc
./zcc --version
```

Szczegóły architektury: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
Plan etapów: [docs/ROADMAP.md](docs/ROADMAP.md)

## Status

✅ **Działa - "hello world" kompiluje się i uruchamia naprawdę.**
Preprocesor, parser, sema i codegen (x86-64 Linux, przez `as`/`ld`) są
wpięte w pełen pipeline. `./zcc program.c -o program && ./program`
produkuje prawdziwy plik ELF, statycznie linkowany domyślnie, z
działającym `printf` i resztą libc. Zweryfikowane end-to-end (w tym
rekurencja, struktury, wskaźniki, enum+switch, wskaźniki do funkcji,
**float/double przez SysV XMM** — arytmetyka, porównania, przeplatane
wywołania wariadyczne typu `printf("%d %f", i, d)`) w `tests/run_tests.nim`.

Uczciwie: to wciąż "MVP" bez optymalizacji (prosty model stack-machine,
nie alokator rejestrów) i ze świadomymi lukami - **struct/union nie mogą
być przekazywane ani zwracane przez wartość** w wywołaniach funkcji,
`-shared` nieobsługiwane, tylko target x86_64-linux generuje kod. Każda
z tych luk zgłasza czytelny błąd kompilacji, nigdy nie psuje kodu po
cichu. Pełna, aktualna lista: nagłówek komentarza w
`src/codegen/codegen.nim` i `docs/ROADMAP.md` (etap 3).

```sh
./zcc program.c -o program && ./program   # pełna kompilacja + link + uruchomienie
./zcc -c plik.c -o plik.o                 # tylko obiekt (bez linkowania)
./zcc -S plik.c -o plik.s                 # tylko asembler (do inspekcji)
./zcc -fsyntax-only plik.c                # sparsuj + sprawdź semantycznie, bez codegenu
./zcc --dump-ast plik.c                   # jak wyżej + wypisz drzewo AST
./zcc -E plik.c                           # tylko preprocesor
nimble test                                # pełny zestaw testów (w tym end-to-end codegenu)
```

Dodatkowo zaimplementowane jako flagi/moduły niezależne od parsera:
hardening (`--hardened=`), sanitizery (`-fsanitize=`), cross-compilation
(`--target=`), LTO (`--lto=`), reproducible builds (`--reproducible`),
`-MM`/`-MMD`, cache builda (realnie spięty z `-c`/link), config projektu
(`zcc.toml`), plugin API (`--plugin=`). Szczegóły i uczciwa lista
ograniczeń każdego: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
