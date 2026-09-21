#!/usr/bin/env janet
# build.janet -- sterownik budowania zcc (Zenit C Compiler)
#
# Jedno miejsce, które wie, JAK zbudować, przetestować i "zainstalować do
# katalogu stagingowego" zcc. Używają go dwie strony:
#
#   * człowiek / CI:      janet build.janet <polecenie>
#   * packaging/recipe.janet (pakiet .zpk) -- deleguje tu budowanie i staging,
#     zamiast duplikować tę logikę.
#
# Sam zcc jest programem w Nim i buduje się przez `nimble` (patrz zcc.nimble);
# ten plik jest cienką, przenośną nakładką (bez make/sh), więc zachowuje się
# tak samo na każdym systemie, na którym jest `janet` i `nimble`.
#
# Polecenia (domyślne: build):
#
#   build                  nimble build -y              -> ./zcc
#   release                nimble buildRelease          -> ./bin/zcc (-d:release)
#   test                   nimble test                  (pełny zestaw testów)
#   smoke [--bin=PATH]     szybki test dymny gotowej binarki (domyślnie bin/zcc,
#                          a jeśli jej nie ma, ./zcc)
#   stage DIR [--bin=PATH] instaluje binarkę + dokumentację do DIR (układ
#                          "od /": usr/local/bin/zcc itd.) -- to woła recipe.janet
#   check-version          sprawdza spójność wersji: zcc.nimble, packaging/zpk.build
#                          i stała Version w src/main.nim (część przed "-")
#   clean                  usuwa ./zcc, ./bin, ./nimcache i packaging/out
#   help                   ta lista
#
# Można wywołać z dowolnego katalogu (np. `janet ../build.janet stage ...` z
# packaging/): ścieżki repo liczone są od położenia TEGO pliku, a ścieżki
# podane przez użytkownika (DIR, --bin=) -- od katalogu wywołania.
#
# Kody wyjścia: 0 = sukces, 1 = błąd (komunikat na stderr).
#
# UWAGA o smoke teście: celowo NIE kompiluje programu z #include <stdio.h> --
# zcc nie radzi sobie jeszcze z realnymi nagłówkami glibc (preprocesor
# zatrzymuje się na makrze funkcyjnym __GLIBC_USE w #if). Test dymny używa
# więc własnej deklaracji printf, dokładnie jak testy w tests/run_tests.nim.

# ---------------------------------------------------------------------------
# Pomocnicze
# ---------------------------------------------------------------------------

(defn- fail [& msg]
  (eprint "build.janet: " (string ;msg))
  (os/exit 1))

(defn- dirname [path]
  (def i (last (string/find-all "/" path)))
  (cond
    (nil? i) "."
    (= i 0) "/"
    (string/slice path 0 i)))

# Katalog, z którego wywołano skrypt -- zapamiętany ZANIM zrobimy os/cd do
# korzenia repo, żeby względne argumenty użytkownika nadal znaczyły to, co
# użytkownik miał na myśli.
(def- orig-cwd (os/cwd))

(defn- abs-path
  "Ścieżka bezwzględna; względne liczone od katalogu wywołania skryptu."
  [p]
  (if (string/has-prefix? "/" p) p (string orig-cwd "/" p)))

# Korzeń repo = katalog, w którym leży TEN plik -- niezależnie od cwd, z
# którego go wywołano (recipe.janet uruchamia się z packaging/).
(def root
  (let [d (abs-path (dirname (or (dyn :current-file) "build.janet")))]
    (or (os/realpath d) d)))

(defn- path-join [& parts] (string/join parts "/"))

(defn- run
  ``Uruchamia polecenie (argv, z wyszukiwaniem w PATH), dziedzicząc stdout/stderr.
  Przy niezerowym kodzie kończy cały skrypt błędem.``
  [& argv]
  (print "[build] $ " (string/join argv " "))
  (flush)
  (def code
    (try (os/execute argv :p)
      ([err] (fail "nie udało się uruchomić '" (first argv) "': " err
                   " -- czy jest w PATH?"))))
  (unless (zero? code)
    (fail "'" (string/join argv " ") "' zakończone kodem " code)))

(defn- run-code
  "Jak `run`, ale zwraca kod wyjścia zamiast kończyć skrypt (do sprawdzania oczekiwanego wyniku)."
  [& argv]
  (try (os/execute argv :p) ([_] -1)))

(defn- which
  "Ścieżka do pliku wykonywalnego `exe` w PATH albo nil."
  [exe]
  (label found
    (each dir (string/split ":" (or (os/getenv "PATH") ""))
      (unless (empty? dir)
        (def p (string dir "/" exe))
        (def perms (os/stat p :permissions))
        (when (and perms (= :file (os/stat p :mode)) (string/find "x" perms))
          (return found p))))
    nil))

(defn- file? [p] (= :file (os/stat p :mode)))
(defn- dir? [p] (= :directory (os/stat p :mode)))

(defn- mkdir-p
  "mkdir -p bez powłoki: tworzy każdy brakujący poziom ścieżki."
  [path]
  (var acc (if (string/has-prefix? "/" path) "" nil))
  (each part (string/split "/" path)
    (unless (empty? part)
      (set acc (if acc (string acc "/" part) part))
      (unless (dir? acc)
        (os/mkdir acc)))))

(defn- copy-file
  "Kopiuje plik (bajt w bajt), tworzy brakujące katalogi docelowe i ustawia tryb."
  [src dest mode]
  (unless (file? src) (fail "brak pliku do skopiowania: " src))
  (mkdir-p (dirname dest))
  (spit dest (slurp src))
  (os/chmod dest mode))

(defn- opt-value
  "Wartość flagi --name=VALUE z listy argumentów (albo nil)."
  [args name]
  (def prefix (string "--" name "="))
  (var found nil)
  (each a args
    (when (string/has-prefix? prefix a)
      (set found (string/slice a (length prefix)))))
  found)

(defn- positional
  "Argumenty niebędące flagami --*."
  [args]
  (filter |(not (string/has-prefix? "--" $)) args))

(defn- default-bin
  "Domyślna binarka: bin/zcc (release), a w razie braku ./zcc (nimble build)."
  []
  (def release-bin (path-join root "bin" "zcc"))
  (def plain-bin (path-join root "zcc"))
  (cond
    (file? release-bin) release-bin
    (file? plain-bin) plain-bin
    (fail "nie znaleziono binarki zcc (szukano: " release-bin ", " plain-bin
          ") -- najpierw: janet build.janet release")))

(defn- bin-from
  "Binarka z --bin=PATH (względna liczona od katalogu wywołania) albo domyślna."
  [args]
  (def given (opt-value args "bin"))
  (def bin (if given (abs-path given) (default-bin)))
  (unless (file? bin) (fail "nie znaleziono binarki: " bin))
  bin)

(defn- need-tool [exe hint]
  (unless (which exe)
    (fail "brak '" exe "' w PATH -- " hint)))

# ---------------------------------------------------------------------------
# Polecenia
# ---------------------------------------------------------------------------

(defn cmd-build [_args]
  (need-tool "nimble" "zainstaluj Nim >= 1.6 (razem z nimble)")
  (run "nimble" "build" "-y")
  (print "[build] gotowe: " (path-join root "zcc")))

(defn cmd-release [_args]
  (need-tool "nimble" "zainstaluj Nim >= 1.6 (razem z nimble)")
  (run "nimble" "buildRelease")
  (print "[build] gotowe: " (path-join root "bin" "zcc")))

(defn cmd-test [_args]
  (need-tool "nimble" "zainstaluj Nim >= 1.6 (razem z nimble)")
  (run "nimble" "test"))

(defn cmd-smoke [args]
  (def bin (bin-from args))

  # 1) Binarka w ogóle się uruchamia i przedstawia się jako zcc.
  (print "[smoke] " bin " --version")
  (unless (zero? (run-code bin "--version"))
    (fail "'" bin " --version' nie zakończyło się sukcesem (zła architektura? uszkodzony plik?)"))

  # 2) Frontend bez codegenu -- nie wymaga binutils.
  (def tmp (path-join (or (os/getenv "TMPDIR") "/tmp")
                      (string "zcc-smoke-" (os/getpid))))
  (mkdir-p tmp)
  (def src (path-join tmp "smoke.c"))
  (spit src (string "int printf(const char *fmt, ...);\n"
                    "int main(void) { printf(\"zcc smoke ok\\n\"); return 7; }\n"))
  (print "[smoke] -fsyntax-only")
  (unless (zero? (run-code bin "-fsyntax-only" src))
    (run "rm" "-rf" tmp)
    (fail "-fsyntax-only nie przeszło na prostym programie testowym"))

  # 3) Pełna kompilacja + uruchomienie -- tylko jeśli jest toolchain hosta
  #    (as + ld z binutils). Bez niego uczciwie pomijamy, nie failujemy: tak
  #    samo robi tests/run_tests.nim.
  (if (and (which "as") (which "ld"))
    (do
      (def exe (path-join tmp "smoke.bin"))
      (print "[smoke] kompilacja + linkowanie + uruchomienie")
      (unless (zero? (run-code bin src "-o" exe))
        (run "rm" "-rf" tmp)
        (fail "kompilacja programu testowego zakończona błędem"))
      (def code (run-code exe))
      (unless (= code 7)
        (run "rm" "-rf" tmp)
        (fail "program testowy zwrócił kod " code ", oczekiwano 7")))
    (print "[smoke] UWAGA: brak 'as'/'ld' w PATH -- pominięto krok kompilacji do ELF"))

  (run "rm" "-rf" tmp)
  (print "[smoke] OK"))

(defn cmd-stage [args]
  (def dest-arg (first (positional args)))
  (unless dest-arg (fail "użycie: janet build.janet stage DIR [--bin=PATH]"))
  (def dest (abs-path dest-arg))
  (def bin (bin-from args))

  # Układ "od /" -- zgodny z konwencją recipe zpk (usr/local/bin/...).
  (def bin-dest (path-join dest "usr" "local" "bin" "zcc"))
  (def doc-dir (path-join dest "usr" "local" "share" "doc" "zcc"))

  (copy-file bin bin-dest 8r755)

  # Dokumentacja i licencja: brak któregoś pliku nie wywala buildu, ale
  # zgłaszamy to ostrzeżeniem.
  (each [rel target] [["README.md" "README.md"]
                      ["LICENSE" "LICENSE"]
                      ["docs/ARCHITECTURE.md" "ARCHITECTURE.md"]
                      ["docs/ROADMAP.md" "ROADMAP.md"]
                      ["examples/zcc.toml.example" "examples/zcc.toml.example"]
                      ["examples/plugins/no_tabs_lint.c" "examples/plugins/no_tabs_lint.c"]]
    (def src (path-join root rel))
    (if (file? src)
      (copy-file src (path-join doc-dir target) 8r644)
      (eprint "build.janet: ostrzeżenie: brak " src " -- pomijam")))

  (print "[stage] " bin-dest)
  (print "[stage] " doc-dir "/ (README, LICENSE, docs, examples)"))

# -- kontrola spójności wersji ------------------------------------------------

(defn- quoted-value
  "Tekst między pierwszą parą cudzysłowów w linii (albo nil)."
  [line]
  (def a (string/find "\"" line))
  (when a
    (def b (string/find "\"" line (+ a 1)))
    (when b (string/slice line (+ a 1) b))))

(defn- first-version-in
  "Pierwsza linia pliku zaczynająca się (po trimie) od `prefix` -> wartość w cudzysłowie."
  [path prefix]
  (unless (file? path) (fail "brak pliku: " path))
  (var result nil)
  (each line (string/split "\n" (slurp path))
    (when (and (nil? result) (string/has-prefix? prefix (string/trim line)))
      (set result (quoted-value line))))
  result)

(defn cmd-check-version [_args]
  (def nimble-v (first-version-in (path-join root "zcc.nimble") "version"))
  (def zpk-v (first-version-in (path-join root "packaging" "zpk.build") "version"))
  (def main-v-full (first-version-in (path-join root "src" "main.nim") "const Version"))
  # "0.0.1-dev" -> rdzeń "0.0.1" (przyrostek -dev to etykieta stanu kodu, a nie
  # wersja pakietu; zpk.build i zcc.nimble trzymają samą liczbę).
  (def main-v (when main-v-full (first (string/split "-" main-v-full))))

  (print "zcc.nimble          : " (or nimble-v "?"))
  (print "packaging/zpk.build : " (or zpk-v "?"))
  (print "src/main.nim        : " (or main-v-full "?") " (rdzeń: " (or main-v "?") ")")

  (unless (and nimble-v zpk-v main-v)
    (fail "nie udało się odczytać wersji ze wszystkich trzech plików"))
  (unless (and (= nimble-v zpk-v) (= nimble-v main-v))
    (fail "wersje są niespójne -- zsynchronizuj ręcznie (HCL w zpk.build nie ma odwołań do innych plików)"))
  (print "OK: wersje spójne (" nimble-v ")"))

(defn cmd-clean [_args]
  (each rel ["zcc" "bin" "nimcache" "packaging/out"]
    (def p (path-join root rel))
    (when (os/stat p)
      (print "[clean] " p)
      (run "rm" "-rf" p))))

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

(defn cmd-help [_args]
  (print ``
build.janet -- sterownik budowania zcc

Użycie: janet build.janet [polecenie] [argumenty]

  build                   nimble build -y            -> ./zcc
  release                 nimble buildRelease        -> ./bin/zcc
  test                    nimble test
  smoke [--bin=PATH]      test dymny gotowej binarki
  stage DIR [--bin=PATH]  instaluje binarkę i dokumentację do DIR (układ "od /")
  check-version           spójność wersji: zcc.nimble / zpk.build / src/main.nim
  clean                   usuwa artefakty budowania
  help                    ta lista
``))

(def commands
  {"build" cmd-build
   "release" cmd-release
   "test" cmd-test
   "smoke" cmd-smoke
   "stage" cmd-stage
   "check-version" cmd-check-version
   "clean" cmd-clean
   "help" cmd-help
   "--help" cmd-help
   "-h" cmd-help})

(defn main [& argv]
  # argv[0] to nazwa skryptu -- reszta to polecenie i jego argumenty.
  (def args (tuple/slice argv 1))
  (def name (if (empty? args) "build" (first args)))
  (def handler (get commands name))
  (unless handler
    (eprint "build.janet: nieznane polecenie '" name "'\n")
    (cmd-help [])
    (os/exit 1))
  # Narzędzia (nimble) mają działać w korzeniu repo niezależnie od cwd
  # wywołującego -- wszystkie ścieżki powyżej są już bezwzględne.
  (os/cd root)
  (handler (tuple/slice args 1)))
