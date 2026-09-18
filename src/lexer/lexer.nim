import std/[strutils]
import tokens
import ../options
import ../diagnostics

type
  Lexer* = object
    src: string
    pos: int
    line, col: int
    file: string
    std: CStd
    diags*: seq[Diagnostic]   ## zebrane diagnostyki (błędy/ostrzeżenia)

proc newLexer*(src, file: string, std: CStd): Lexer =
  Lexer(src: src, pos: 0, line: 1, col: 1, file: file, std: std, diags: @[])

proc atEnd(l: Lexer): bool = l.pos >= l.src.len
proc cur(l: Lexer): char = if l.atEnd: '\0' else: l.src[l.pos]
proc peek(l: Lexer, off = 1): char =
  let p = l.pos + off
  if p >= l.src.len: '\0' else: l.src[p]

proc advance(l: var Lexer) =
  if not l.atEnd:
    if l.src[l.pos] == '\n':
      inc l.line
      l.col = 1
    else:
      inc l.col
    inc l.pos

proc mkTok(l: Lexer, kind: TokenKind, text: string, startLine, startCol: int): Token =
  Token(kind: kind, text: text, line: startLine, col: startCol, file: l.file)

proc skipWhitespaceAndComments(l: var Lexer) =
  while not l.atEnd:
    let c = l.cur
    if c in {' ', '\t', '\r', '\n'}:
      l.advance()
    elif c == '/' and l.peek() == '/':
      while not l.atEnd and l.cur != '\n': l.advance()
    elif c == '/' and l.peek() == '*':
      l.advance(); l.advance()
      while not l.atEnd and not (l.cur == '*' and l.peek() == '/'):
        l.advance()
      if not l.atEnd:
        l.advance(); l.advance()
    else:
      break

proc isIdentStart(c: char): bool = c.isAlphaAscii or c == '_'
proc isIdentCont(c: char): bool = c.isAlphaNumeric or c == '_'

proc lexIdentOrKeyword(l: var Lexer): Token =
  let startLine = l.line
  let startCol = l.col
  var s = ""
  while not l.atEnd and isIdentCont(l.cur):
    s.add l.cur
    l.advance()
  let kind = if isKeywordFor(s, l.std): tkKeyword else: tkIdent
  result = l.mkTok(kind, s, startLine, startCol)

proc lexNumber(l: var Lexer): Token =
  let startLine = l.line
  let startCol = l.col
  var s = ""
  var isFloat = false
  # bardzo uproszczone na tym etapie: brak jeszcze hex-float, binarnych
  # literałów (0b...), separatorów cyfr z C23 (') - TODO w kolejnej iteracji
  while not l.atEnd and (l.cur.isDigit or l.cur == '.'):
    if l.cur == '.': isFloat = true
    s.add l.cur
    l.advance()
  # sufiksy: u/U, l/L, f/F itd.
  while not l.atEnd and l.cur in {'u','U','l','L','f','F'}:
    s.add l.cur
    l.advance()
  result = l.mkTok(if isFloat: tkFloatLit else: tkIntLit, s, startLine, startCol)

proc lexString(l: var Lexer, quote: char, kind: TokenKind): Token =
  let startLine = l.line
  let startCol = l.col
  var s = ""
  s.add l.cur
  l.advance()
  while not l.atEnd and l.cur != quote:
    if l.cur == '\\' and not l.atEnd:
      s.add l.cur
      l.advance()
      if not l.atEnd:
        s.add l.cur
        l.advance()
    else:
      s.add l.cur
      l.advance()
  if not l.atEnd:
    s.add l.cur # zamykający cudzysłów
    l.advance()
  result = l.mkTok(kind, s, startLine, startCol)

const PunctSet = "+-*/%=<>!&|^~?:;,.(){}[]#"

proc lexPunct(l: var Lexer): Token =
  let startLine = l.line
  let startCol = l.col
  # najdłuższe dopasowanie najpierw - lista do rozbudowy (np. <<=, ->, ...)
  const multi3 = ["<<=", ">>=", "...", "->*"]
  const multi2 = ["==","!=","<=",">=","&&","||","++","--","->",
                  "+=","-=","*=","/=","%=","&=","|=","^=","<<",">>","::"]
  for m in multi3:
    if l.src.len - l.pos >= 3 and l.src[l.pos ..< l.pos+3] == m:
      for _ in 0..<3: l.advance()
      return l.mkTok(tkPunct, m, startLine, startCol)
  for m in multi2:
    if l.src.len - l.pos >= 2 and l.src[l.pos ..< l.pos+2] == m:
      for _ in 0..<2: l.advance()
      return l.mkTok(tkPunct, m, startLine, startCol)
  let c = l.cur
  l.advance()
  result = l.mkTok(tkPunct, $c, startLine, startCol)

proc next*(l: var Lexer): Token =
  l.skipWhitespaceAndComments()
  if l.atEnd:
    return l.mkTok(tkEOF, "", l.line, l.col)
  let c = l.cur
  if isIdentStart(c):
    return l.lexIdentOrKeyword()
  if c.isDigit or (c == '.' and l.peek().isDigit):
    return l.lexNumber()
  if c == '"':
    return l.lexString('"', tkStringLit)
  if c == '\'':
    return l.lexString('\'', tkCharLit)
  if c in PunctSet:
    return l.lexPunct()
  let startLine = l.line
  let startCol = l.col
  l.advance()
  # Częsty przypadek: "smart quotes" wklejone z edytora/Worda zamiast '"'.
  # To właśnie przykład diagnostyki z sugestią - klasyczny błąd gcc
  # zgłasza tu tylko "stray '\xE2' in program".
  var sug = ""
  if c in {'\xE2', '\x80'}:
    sug = "czy chodziło o zwykły cudzysłów prosty \" zamiast typograficznego?"
  l.diags.add errAt(l.file, startLine, startCol,
    "nieoczekiwany znak w kodzie: '" & $c & "'", suggestion = sug)
  return l.mkTok(tkUnknown, $c, startLine, startCol)

iterator tokens*(l: var Lexer): Token =
  while true:
    let t = l.next()
    yield t
    if t.kind == tkEOF: break
