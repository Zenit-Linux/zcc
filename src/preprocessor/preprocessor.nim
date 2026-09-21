import std/[os, strutils, sets]
import pp_lexer
import macros
import pp_expr
import ../options

type PreprocessError* = object of ValueError

type CondState = enum csActive, csInactiveWaiting, csInactiveDone
  ## csActive: gałąź aktualnie emitowana
  ## csInactiveWaiting: ta gałąź nieaktywna, ale kolejny #elif/#else może
  ##   jeszcze coś aktywować
  ## csInactiveDone: warunek w tym bloku #if już był kiedyś prawdziwy -
  ##   wszystkie kolejne #elif/#else w tym bloku mają być pomijane

type Preprocessor* = object
  mt: MacroTable
  includeDirs: seq[string]
  std: CStd
  condStack: seq[CondState]
  pragmaOnceFiles: HashSet[string]
  includeDepth: int

proc stdVersionMacro(std: CStd): string =
  ## __STDC_VERSION__ per standard - wartości jak w realnych kompilatorach.
  case std
  of stdC99: "199901L"
  of stdC11: "201112L"
  of stdC17: "201710L"
  of stdC23: "202311L"

proc newPreprocessor*(std: CStd, includeDirs: seq[string]): Preprocessor =
  result = Preprocessor(mt: newMacroTable(), includeDirs: includeDirs,
                         std: std, condStack: @[], pragmaOnceFiles: initHashSet[string](),
                         includeDepth: 0)
  template defObj(n, v: string) =
    result.mt.define(MacroDef(name: n, kind: mkObject, params: @[], variadic: false,
      body: @[PpToken(kind: ptNumber, text: v)]))
  defObj("__STDC__", "1")
  defObj("__STDC_VERSION__", stdVersionMacro(std))
  defObj("__STDC_HOSTED__", "1")
  defObj("__ZCC__", "1")

proc currentlyActive(pp: Preprocessor): bool =
  for s in pp.condStack:
    if s != csActive: return false
  true

proc findEndOfLine(toks: seq[PpToken], start: int): int =
  ## Zwraca indeks pierwszego tokenu KOLEJNEJ linii (albo len(toks)).
  result = start
  if start >= toks.len: return
  let line0 = toks[start].line
  while result < toks.len and toks[result].line == line0:
    inc result

proc resolveInclude(pp: Preprocessor, name: string, isSystem: bool, fromDir: string): string =
  if not isSystem:
    let local = fromDir / name
    if fileExists(local): return local
  for d in pp.includeDirs:
    let cand = d / name
    if fileExists(cand): return cand
  return ""

proc parseMacroDef(toks: seq[PpToken], lineEnd: int): MacroDef =
  ## toks[0] to nazwa makra (token zaraz po '#define'), reszta do lineEnd
  ## to ewentualne '(' params ')' i ciało.
  if toks.len == 0 or toks[0].kind != ptIdent:
    raise newException(PreprocessError, "oczekiwano nazwy makra po #define")
  result.name = toks[0].text
  var i = 1
  if i < toks.len and toks[i].kind == ptPunct and toks[i].text == "(" and not toks[i].spaceBefore:
    result.kind = mkFunction
    inc i
    while i < lineEnd and not (toks[i].kind == ptPunct and toks[i].text == ")"):
      if toks[i].kind == ptPunct and toks[i].text == "...":
        result.variadic = true
      elif toks[i].kind == ptIdent:
        result.params.add toks[i].text
      inc i
    inc i # ')'
  else:
    result.kind = mkObject
  result.body = toks[i ..< lineEnd]

proc mapItRaw(toks: seq[PpToken]): string =
  var parts: seq[string] = @[]
  for t in toks: parts.add t.text
  parts.join(" ")

proc processTokens(pp: var Preprocessor, toks: seq[PpToken], curFile: string,
                    curDir: string, output: var seq[PpToken])

proc handleDirective(pp: var Preprocessor, toks: seq[PpToken], start: int,
                      curFile: string, curDir: string, output: var seq[PpToken]): int =
  ## toks[start] == '#'. Zwraca indeks pierwszego tokenu ZA tą dyrektywą.
  let lineEnd = findEndOfLine(toks, start)
  if start + 1 >= lineEnd:
    return lineEnd  # goła '#' (pusta dyrektywa) - dozwolone, no-op
  let kw = toks[start + 1]
  let body = toks[start + 2 ..< lineEnd]
  let active = pp.currentlyActive()

  case kw.text
  of "define":
    if active:
      pp.mt.define(parseMacroDef(body, body.len))
  of "undef":
    if active and body.len > 0 and body[0].kind == ptIdent:
      pp.mt.undef(body[0].text)
  of "include":
    if active:
      if body.len == 0:
        raise newException(PreprocessError, curFile & ": #include bez argumentu")
      var name: string
      var isSystem: bool
      if body[0].kind == ptString:
        name = body[0].text[1 ..< ^1]
        isSystem = false
      elif body[0].kind == ptPunct and body[0].text == "<":
        var s = ""
        var j = 1
        while j < body.len and not (body[j].kind == ptPunct and body[j].text == ">"):
          s.add body[j].text
          inc j
        name = s
        isSystem = true
      else:
        # #include z makrem generującym nazwę pliku - rozwiń najpierw
        var activeSet: seq[string] = @[]
        let expanded = expand(pp.mt, body, activeSet)
        if expanded.len > 0 and expanded[0].kind == ptString:
          name = expanded[0].text[1 ..< ^1]
          isSystem = false
        else:
          raise newException(PreprocessError, curFile & ": nieobsługiwana forma #include")
      let resolved = resolveInclude(pp, name, isSystem, curDir)
      if resolved.len == 0:
        raise newException(PreprocessError,
          curFile & ": nie znaleziono nagłówka: " & name &
          " (przeszukano katalog źródła + -I: " & $pp.includeDirs & ")")
      if resolved notin pp.pragmaOnceFiles:
        if pp.includeDepth > 200:
          raise newException(PreprocessError, "zbyt głębokie zagnieżdżenie #include (>200) - prawdopodobny cykl")
        inc pp.includeDepth
        let incSrc = readFile(resolved)
        let incToks = tokenizeAll(incSrc)
        processTokens(pp, incToks, resolved, resolved.parentDir, output)
        dec pp.includeDepth
  of "ifdef":
    if body.len > 0 and body[0].kind == ptIdent:
      let cond = active and pp.mt.isDefined(body[0].text)
      pp.condStack.add(if cond: csActive else: csInactiveWaiting)
    else:
      pp.condStack.add csInactiveDone
  of "ifndef":
    if body.len > 0 and body[0].kind == ptIdent:
      let cond = active and not pp.mt.isDefined(body[0].text)
      pp.condStack.add(if cond: csActive else: csInactiveWaiting)
    else:
      pp.condStack.add csInactiveDone
  of "if":
    if active:
      let v = evalConstExpr(pp.mt, body)
      pp.condStack.add(if v != 0: csActive else: csInactiveWaiting)
    else:
      pp.condStack.add csInactiveDone
  of "elif":
    if pp.condStack.len == 0:
      raise newException(PreprocessError, curFile & ": #elif bez odpowiadającego #if")
    case pp.condStack[^1]
    of csActive:
      pp.condStack[^1] = csInactiveDone
    of csInactiveWaiting:
      # aktywne tylko jeśli WSZYSTKIE otaczające bloki też są aktywne
      var outerActive = true
      for i in 0 ..< pp.condStack.len - 1:
        if pp.condStack[i] != csActive: outerActive = false
      if outerActive:
        let v = evalConstExpr(pp.mt, body)
        if v != 0: pp.condStack[^1] = csActive
    of csInactiveDone:
      discard
  of "else":
    if pp.condStack.len == 0:
      raise newException(PreprocessError, curFile & ": #else bez odpowiadającego #if")
    case pp.condStack[^1]
    of csActive: pp.condStack[^1] = csInactiveDone
    of csInactiveWaiting: pp.condStack[^1] = csActive
    of csInactiveDone: discard
  of "endif":
    if pp.condStack.len == 0:
      raise newException(PreprocessError, curFile & ": #endif bez odpowiadającego #if")
    discard pp.condStack.pop()
  of "pragma":
    if active and body.len > 0 and body[0].kind == ptIdent and body[0].text == "once":
      pp.pragmaOnceFiles.incl curFile
    # inne #pragma: na razie ciche no-op (TODO: #pragma pack itp. w sema)
  of "error":
    if active:
      raise newException(PreprocessError, curFile & ": #error " & body.mapItRaw)
  of "warning":
    discard  # TODO: przekierować przez diagnostics.nim jako sevWarning
  of "line":
    discard  # TODO: przestawianie __LINE__/__FILE__ raportowanego w diagnostyce
  else:
    if active:
      raise newException(PreprocessError, curFile & ": nieznana dyrektywa #" & kw.text)

  result = lineEnd

proc processTokens(pp: var Preprocessor, toks: seq[PpToken], curFile: string,
                    curDir: string, output: var seq[PpToken]) =
  var i = 0
  while i < toks.len:
    let t = toks[i]
    if t.kind == ptEOF: break
    if t.kind == ptHash and t.atLineStart:
      i = handleDirective(pp, toks, i, curFile, curDir, output)
      continue
    if pp.currentlyActive():
      let lineEnd = findEndOfLine(toks, i)
      var activeSet: seq[string] = @[]
      let expanded = expand(pp.mt, toks[i ..< lineEnd], activeSet)
      output.add expanded
      i = lineEnd
    else:
      i = findEndOfLine(toks, i)

## Punkt wejścia: preprocesuje plik i zwraca tekst gotowy dla lexer.nim.
## Rekonstrukcja tekstu jest uproszczona (tokeny łączone spacją, z
## zachowaniem oryginalnych znaków nowej linii tam gdzie to możliwe) -
## wystarczające, bo src/lexer/lexer.nim jest tokenizerem free-form i nie
## zależy od dokładnego formatowania białych znaków.
proc preprocessFile*(path: string, std: CStd, includeDirs: seq[string]): string =
  var pp = newPreprocessor(std, includeDirs)
  let src = readFile(path)
  let toks = tokenizeAll(src)
  var output: seq[PpToken] = @[]
  processTokens(pp, toks, path, path.parentDir, output)
  if pp.condStack.len > 0:
    raise newException(PreprocessError, path & ": niezamknięty #if/#ifdef (brakuje #endif)")

  var parts: seq[string] = @[]
  var lastLine = -1
  for t in output:
    if lastLine >= 0 and t.line != lastLine:
      parts.add "\n"
    elif t.spaceBefore:
      parts.add " "
    parts.add t.text
    lastLine = t.line
  result = parts.join("")
