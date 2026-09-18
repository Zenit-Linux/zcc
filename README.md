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
  parser/           # AST C (docelowo)
  codegen/          # backend (docelowo: LLVM albo bezpośrednio ASM/obj)
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

🚧 **Preprocesor działa** (`#define`, `#include`, `#if`/`#ifdef`, `##`/`#`) —
`-E` i `--dump-tokens` już coś realnie robią. Parser/sema/codegen wciąż
w budowie (etap 2+ z roadmapy).

Dodatkowo zaimplementowane jako flagi/moduły niezależne od parsera:
hardening (`--hardened=`), sanitizery (`-fsanitize=`), cross-compilation
(`--target=`), LTO (`--lto=`), reproducible builds (`--reproducible`),
`-MM`/`-MMD`, cache builda, config projektu (`zcc.toml`), plugin API
(`--plugin=`). Szczegóły i uczciwa lista ograniczeń każdego:
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).
