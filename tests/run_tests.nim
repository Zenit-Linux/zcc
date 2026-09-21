import std/[os, strutils, osproc]
import ../src/lexer/[lexer, tokens]
import ../src/preprocessor/preprocessor as pp
import ../src/parser/[parser, ast]
import ../src/sema/sema
import ../src/codegen/codegen
import ../src/target
import ../src/linker
import ../src/options
import ../src/diagnostics

var passed = 0
var failed = 0

proc check(name: string, cond: bool) =
  if cond:
    inc passed
    echo "  ok   ", name
  else:
    inc failed
    echo "FAIL   ", name

proc countErrors(diags: seq[Diagnostic]): int =
  for d in diags:
    if d.severity == sevError: inc result

proc tokenize(src, file: string): seq[Token] =
  var lx = newLexer(src, file, stdC17)
  for t in lx.tokens(): result.add t

proc parseFile(path: string): tuple[unit: Node, diags: seq[Diagnostic]] =
  let src = pp.preprocessFile(path, stdC17, @[])
  let toks = tokenize(src, path)
  parseTokens(toks, path, stdC17)

proc parseSrc(src: string): tuple[unit: Node, diags: seq[Diagnostic]] =
  let toks = tokenize(src, "<test>")
  parseTokens(toks, "<test>", stdC17)

## Szuka pierwszego węzła o danym kind w płytkim przeszukiwaniu DFS
## (wystarcza do testów - nie potrzebujemy generycznego API odwiedzin
## na tym etapie).
proc findFirst(n: Node, kind: NodeKind): Node =
  if n.isNil: return nil
  if n.kind == kind: return n
  for c in [n.a, n.b, n.c, n.d]:
    let r = findFirst(c, kind)
    if not r.isNil: return r
  for c in n.list:
    let r = findFirst(c, kind)
    if not r.isNil: return r
  nil

## Kompiluje `src` (jedno "wirtualne" tłumaczenie) całą prawdziwą drogą
## front-endu i backendu (parser -> sema -> codegen -> `as` -> `ld`),
## uruchamia powstały plik wykonywalny i sprawdza kod wyjścia oraz
## (opcjonalnie) dokładne stdout. Pomija test (zwraca cicho), jeśli `as`/
## `ld` nie są dostępne na hoście - to sprawdzenie toolchaina, nie
## kompilatora, więc brak binutils nie powinien fałszywie psuć wyniku
## reszty testów front-endu w środowiskach bez pełnego toolchaina.
var codegenToolchainMissing = false
proc compileAndRun(name, src: string, expectedExit: int, expectedStdout = "") =
  if codegenToolchainMissing: return
  var slug = ""
  for ch in name:
    if ch in {'a'..'z', 'A'..'Z', '0'..'9'}: slug.add ch
    else: slug.add '_'
  let (unit, parseDiags) = parseSrc(src)
  if countErrors(parseDiags) > 0:
    check("[codegen] " & name & ": parser bez błędów", false)
    return
  let semaDiags = runSema(unit, "<test>")
  if countErrors(semaDiags) > 0:
    check("[codegen] " & name & ": sema bez błędów", false)
    return
  let (asmText, cgDiags) = generateModule(unit, "<test>")
  if countErrors(cgDiags) > 0:
    check("[codegen] " & name & ": codegen bez błędów", false)
    return
  let tmpDir = getTempDir() / "zcc-selftest"
  createDir(tmpDir)
  let base = tmpDir / ("t_" & slug)
  let asmPath = base & ".s"
  let objPath = base & ".o"
  let exePath = base & ".bin"
  writeFile(asmPath, asmText)
  let (asOk, asOut) = assembleFile(asmPath, objPath)
  if not asOk:
    if "as: command not found" in asOut or "command not found" in asOut:
      codegenToolchainMissing = true
      return
    check("[codegen] " & name & ": asemblacja (as)", false)
    echo "        ", asOut
    return
  let (linkOk, linkOut) = linkExecutable(@[objPath], exePath, hostTarget(), staticLink = true)
  if not linkOk:
    check("[codegen] " & name & ": linkowanie (ld)", false)
    echo "        ", linkOut
    return
  let (runOut, runCode) = execCmdEx(exePath)
  check("[codegen] " & name & ": kod wyjścia == " & $expectedExit, runCode == expectedExit)
  if runCode != expectedExit:
    echo "        otrzymano kod: ", runCode, "  (stdout: ", runOut, ")"
  if expectedStdout.len > 0:
    check("[codegen] " & name & ": stdout pasuje", runOut == expectedStdout)
    if runOut != expectedStdout:
      echo "        oczekiwano: ", repr(expectedStdout)
      echo "        otrzymano:  ", repr(runOut)

echo "== lexer =="
block:
  let toks = tokenize("int x = 42;", "<test>")
  check("liczba tokenów dla 'int x = 42;' (w tym EOF)", toks.len == 6)  # int x = 42 ; EOF
  check("pierwszy token to słowo kluczowe 'int'",
        toks.len > 0 and toks[0].kind == tkKeyword and toks[0].text == "int")

block:
  let toks = tokenize("\"foo\" \"bar\"", "<test>")
  check("dwa sąsiadujące literały string to dwa osobne tokeny na etapie lexera " &
        "(sklejanie robi parser, patrz parsePrimaryExpr)", toks.len == 3)  # "foo" "bar" EOF

echo "== preprocesor =="
block:
  let src = pp.preprocessFile("tests/c/preprocessor_test.c", stdC17, @[])
  check("MAX(a,b) rozwija się do wyrażenia warunkowego z '?'", "?" in src)
  check("STR(CONCAT(...)) NIE rozwija argumentu przed stringizacją (zgodnie z C: " &
        "operator # wyłącza pre-ekspansję swojego argumentu)",
        "CONCAT(VERSION_MAJOR, VERSION_MINOR)" in src)

echo "== parser: podstawy =="
block:
  let (unit, diags) = parseSrc("int add(int a, int b) { return a + b; }")
  check("brak diagnostyk dla poprawnej funkcji", diags.len == 0)
  check("jedna deklaracja top-level", unit.list.len == 1)
  if unit.list.len == 1:
    let fn = unit.list[0]
    check("rozpoznano nkFuncDef", fn.kind == nkFuncDef)
    check("nazwa funkcji to 'add'", fn.strVal == "add")
    check("dwa parametry", fn.params.len == 2)
    check("typ zwracany to int", not fn.typ.isNil and fn.typ.returnType.kind == tkInt)

block:
  let (unit, diags) = parseSrc("int x, y = 2, *z;")
  check("brak diagnostyk dla wielu deklaratorów naraz", diags.len == 0)
  check("trzy zmienne z jednej deklaracji", unit.list.len == 3)
  if unit.list.len == 3:
    check("z jest wskaźnikiem", unit.list[2].typ.kind == tkPointer)

echo "== parser: deklaratory 'na spirali' =="
block:
  # cmp: wskaźnik do funkcji(int,int) -> int - klasyczny trudny przypadek
  # gramatyki deklaratorów C (patrz komentarz w parser.nim).
  let (unit, diags) = parseSrc("void apply(int (*cmp)(int, int));")
  check("brak diagnostyk dla deklaratora wskaźnika-do-funkcji", diags.len == 0)
  if unit.list.len == 1 and unit.list[0].params.len == 1:
    let cmpTy = unit.list[0].params[0].typ
    check("cmp jest wskaźnikiem", not cmpTy.isNil and cmpTy.kind == tkPointer)
    if not cmpTy.isNil and cmpTy.kind == tkPointer:
      check("cmp wskazuje na funkcję", cmpTy.pointee.kind == tkFunction)
      check("funkcja ma 2 parametry", cmpTy.pointee.paramTypes.len == 2)

block:
  # p: wskaźnik do tablicy 10 intów (a NIE tablica 10 wskaźników - to byłoby `int *p[10]`)
  let (unit, diags) = parseSrc("int (*p)[10];")
  check("brak diagnostyk dla int (*p)[10]", diags.len == 0)
  if unit.list.len == 1:
    let ty = unit.list[0].typ
    check("p jest wskaźnikiem", not ty.isNil and ty.kind == tkPointer)
    if not ty.isNil and ty.kind == tkPointer:
      check("p wskazuje na tablicę", ty.pointee.kind == tkArray)

block:
  let (unit, diags) = parseSrc("""const char *s = "foo" "bar";""")
  check("brak diagnostyk dla sklejanych literałów", diags.len == 0)
  if unit.list.len == 1:
    check("parser sklei \"foo\" \"bar\" w \"foobar\"", unit.list[0].a.strVal == "\"foobar\"")

echo "== parser: struct/union/enum =="
block:
  let (unit, diags) = parseSrc("""
    struct Point { int x; int y; };
    enum Color { RED, GREEN = 5, BLUE };
  """)
  check("brak diagnostyk dla struct+enum", diags.len == 0)
  check("dwie deklaracje tagów", unit.list.len == 2)
  if unit.list.len == 2:
    check("struct Point ma 2 pola", unit.list[0].typ.fields.len == 2)
    check("enum Color ma 3 wartości", unit.list[1].typ.enumerators.len == 3)

echo "== parser: odzyskiwanie po błędach (wiele diagnostyk na przebieg) =="
block:
  let (_, diags) = parseSrc("""
    int add(int a, int b) { return a +; }
    int main(void) { int x = 5 int y = 1; return x; }
  """)
  check("więcej niż jedna diagnostyka po błędach składni (parser nie poddaje się po pierwszej)",
        diags.len >= 2)

echo "== parser: plik parser_smoke.c (funkcje, pętle, wskaźniki, cast) =="
block:
  let (unit, diags) = parseFile("tests/c/parser_smoke.c")
  check("brak diagnostyk parsera dla parser_smoke.c", diags.len == 0)
  check("znaleziono definicję main", not findFirst(unit, nkFuncDef).isNil)

echo "== sema: scoping i redefinicje =="
block:
  let (unit, _) = parseSrc("int x = 1; int x = 2;")
  let diags = runSema(unit, "<test>")
  check("wykryto redefinicję zmiennej", countErrors(diags) >= 1)

block:
  let (unit, _) = parseSrc("""
    int main(void) {
        int counter = 0;
        counter = countr + 1;
        return counter;
    }
  """)
  let diags = runSema(unit, "<test>")
  check("wykryto nieznany identyfikator", countErrors(diags) >= 1)
  var gotSuggestion = false
  for d in diags:
    if d.suggestion.len > 0 and "counter" in d.suggestion:
      gotSuggestion = true
  check("sema sugeruje 'counter' dla literówki 'countr'", gotSuggestion)

block:
  let (unit, _) = parseSrc("""
    enum Color { RED, GREEN, BLUE };
    int main(void) {
        enum Color c = GREEN;
        return (int)c;
    }
  """)
  let diags = runSema(unit, "<test>")
  check("stałe enuma (GREEN) widoczne jako identyfikatory w sema", countErrors(diags) == 0)

block:
  let (unit, _) = parseSrc("void f(void) { break; }")
  let diags = runSema(unit, "<test>")
  check("'break' poza pętlą/switch wykryty przez sema", countErrors(diags) >= 1)

block:
  let (unit, _) = parseFile("tests/c/parser_smoke.c")
  let diags = runSema(unit, "tests/c/parser_smoke.c")
  check("brak błędów sema dla parser_smoke.c", countErrors(diags) == 0)

echo "== codegen: end-to-end (kompilacja -> as -> ld -> uruchomienie) =="

compileAndRun("return literal", """
  int main(void) { return 42; }
""", 42)

compileAndRun("arytmetyka", """
  int main(void) { return (3 + 4) * 2 - 1; }
""", 13)

compileAndRun("rekurencja (silnia)", """
  int fact(int n) { if (n <= 1) return 1; return n * fact(n - 1); }
  int main(void) { return fact(5); }
""", 120)

compileAndRun("pętle i tablice", """
  int main(void) {
    int arr[5] = {1, 2, 3, 4, 5};
    int total = 0;
    for (int i = 0; i < 5; i++) total += arr[i];
    return total;
  }
""", 15)

compileAndRun("struktury i wskaźniki", """
  struct Point { int x; int y; };
  int main(void) {
    struct Point p;
    p.x = 3; p.y = 4;
    struct Point *pp = &p;
    pp->x = pp->x + pp->y;
    return p.x;
  }
""", 7)

compileAndRun("enum i switch", """
  enum Color { RED, GREEN, BLUE };
  int classify(enum Color c) {
    switch (c) {
      case RED: return 1;
      case GREEN: return 2;
      case BLUE: return 3;
      default: return 0;
    }
  }
  int main(void) { return classify(GREEN); }
""", 2)

compileAndRun("wskaźniki do funkcji", """
  int add(int a, int b) { return a + b; }
  int mul(int a, int b) { return a * b; }
  int apply(int (*fn)(int, int), int a, int b) { return fn(a, b); }
  int main(void) { return apply(mul, 6, 7); }
""", 42)

compileAndRun("printf i literały string", """
  int printf(const char *fmt, ...);
  int main(void) {
    printf("wynik: %d\n", 6 * 7);
    return 0;
  }
""", 0, "wynik: 42\n")

compileAndRun("break/continue/goto", """
  int main(void) {
    int total = 0;
    for (int i = 0; i < 10; i++) {
      if (i == 5) break;
      if (i % 2 == 0) continue;
      total += i;
    }
    return total;
  }
""", 4)  # 1 + 3 = 4

echo "== codegen: float/double (SysV XMM, klasyfikacja int/float) =="

compileAndRun("arytmetyka double (cast na int)", """
  int main(void) {
    double x = 3.5;
    double y = 2.25;
    return (int)(x + y * 2.0);
  }
""", 8)  # 3.5 + 4.5 = 8.0

compileAndRun("float (32-bit) osobno od double", """
  float f(float a, float b) { return a * b; }
  int main(void) { return (int)f(2.5f, 4.0f); }
""", 10)

compileAndRun("porównania i warunki na double", """
  int main(void) {
    double d = 10.0;
    if (d > 5.0 && d < 20.0) return 1;
    return 0;
  }
""", 1)

compileAndRun("pętla z przypisaniem złożonym na double", """
  int main(void) {
    double total = 0.0;
    for (double i = 1.0; i <= 5.0; i += 1.0) total += i;
    return (int)total;
  }
""", 15)

compileAndRun("struct z polami double (regresja: kikut bez pól)", """
  struct Vec3 { double x, y, z; };
  double dot(struct Vec3 *a, struct Vec3 *b) {
    return a->x * b->x + a->y * b->y + a->z * b->z;
  }
  int main(void) {
    struct Vec3 v1 = {1.0, 2.0, 3.0};
    struct Vec3 v2 = {4.0, 5.0, 6.0};
    return (int)dot(&v1, &v2);
  }
""", 32)

compileAndRun("printf z przeplecionymi int/float w wywołaniu wariadycznym", """
  int printf(const char *fmt, ...);
  int main(void) {
    printf("%d %f %d %f\n", 1, 2.5, 3, 4.5);
    return 0;
  }
""", 0, "1 2.500000 3 4.500000\n")

compileAndRun("7 argumentów int + 1 double (przepełnienie rejestru int)", """
  int f(int a, int b, int c, int d, int e, int fArg, int g, double h) {
    return a + b + c + d + e + fArg + g + (int)h;
  }
  int main(void) { return f(1, 2, 3, 4, 5, 6, 7, 8.0); }
""", 36)

compileAndRun("unarny minus i konwersje int<->double", """
  int main(void) {
    double x = 5.0;
    double neg = -x;
    int i = 7;
    double di = (double)i / 2.0;
    return (int)(-neg + di);
  }
""", 8)  # -(-5.0) + 3.5 = 8.5 -> (int) obcina do 8

if codegenToolchainMissing:
  echo "  (pominięto testy end-to-end codegenu: brak 'as'/'ld' w tym środowisku)"

echo "== codegen: plik tests/c/codegen_smoke.c =="
if not codegenToolchainMissing:
  let smokeSrc = readFile("tests/c/codegen_smoke.c")
  compileAndRun("codegen_smoke.c", smokeSrc, 0,
    "factorial(10) = 3628800\n" &
    "sum = 15\n" &
    "point = (10, 4)\n" &
    "color = green\n" &
    "global_counter = 5\n" &
    "apply(mul) = 42\n" &
    "buf = hello\n")

echo ""
echo "-----------------------------------------------------------"
echo "zcc test suite: ", passed, " OK, ", failed, " FAIL"
if failed > 0:
  quit(1)
