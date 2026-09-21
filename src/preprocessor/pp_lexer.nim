import std/strutils

type
  PpTokenKind* = enum
    ptIdent, ptNumber, ptString, ptChar, ptPunct, ptHash, ptHashHash,
    ptEOF, ptOther

  PpToken* = object
    kind*: PpTokenKind
    text*: string
    line*, col*: int
    atLineStart*: bool     ## pierwszy niebiały token w fizycznej linii
    spaceBefore*: bool     ## czy bezpośrednio przed nim był biały znak

type
  PpLexer* = object
    src: string
    pos: int
    line, col: int

proc newPpLexer*(src: string): PpLexer = PpLexer(src: src, pos: 0, line: 1, col: 1)

proc atEnd(l: PpLexer): bool = l.pos >= l.src.len
proc cur(l: PpLexer): char = (if l.atEnd: '\0' else: l.src[l.pos])
proc peek(l: PpLexer, off = 1): char =
  let p = l.pos + off
  (if p >= l.src.len: '\0' else: l.src[p])

proc advance(l: var PpLexer) =
  if not l.atEnd:
    if l.src[l.pos] == '\n':
      inc l.line
      l.col = 1
    else:
      inc l.col
    inc l.pos

proc isIdentStart(c: char): bool = c.isAlphaAscii or c == '_'
proc isIdentCont(c: char): bool = c.isAlphaNumeric or c == '_'

## Zwraca WSZYSTKIE tokeny pliku na raz (preprocesor operuje na całych
## liniach/blokach dyrektyw, więc strumieniowanie tu niepotrzebnie
## komplikuje kod obsługi '\' na końcu linii - continuation).
proc tokenizeAll*(src: string): seq[PpToken] =
  result = @[]
  var l = newPpLexer(src)
  var atLineStart = true
  var sawSpace = false

  # Obsługa line-continuation "\<newline>" - standard C mówi, że to
  # sklejenie dwóch linii fizycznych w jedną logiczną, ZANIM cokolwiek
  # innego (komentarze, tokeny) jest interpretowane. Robimy to jako
  # preprocessing tekstu przed właściwą tokenizacją.
  let joined = block:
    var s = ""
    var i = 0
    while i < l.src.len:
      if l.src[i] == '\\' and i+1 < l.src.len and
         (l.src[i+1] == '\n' or (l.src[i+1] == '\r' and i+2 < l.src.len and l.src[i+2] == '\n')):
        if l.src[i+1] == '\r': i += 3 else: i += 2
        # usunięte - logiczna linia ciągnie się dalej, bez wstawiania '\n'
      else:
        s.add l.src[i]
        inc i
    s
  l = newPpLexer(joined)

  while not l.atEnd:
    # białe znaki (poza \n) i komentarze
    while not l.atEnd:
      let c = l.cur
      if c == '\n':
        l.advance()
        atLineStart = true
        sawSpace = false
      elif c in {' ', '\t', '\r'}:
        l.advance()
        sawSpace = true
      elif c == '/' and l.peek() == '/':
        while not l.atEnd and l.cur != '\n': l.advance()
        sawSpace = true
      elif c == '/' and l.peek() == '*':
        l.advance(); l.advance()
        while not l.atEnd and not (l.cur == '*' and l.peek() == '/'):
          l.advance()
        if not l.atEnd: (l.advance(); l.advance())
        sawSpace = true
      else:
        break
    if l.atEnd: break

    let startLine = l.line
    let startCol = l.col
    let c = l.cur

    template emit(k: PpTokenKind, txt: string) =
      result.add PpToken(kind: k, text: txt, line: startLine, col: startCol,
                          atLineStart: atLineStart, spaceBefore: sawSpace)
      atLineStart = false
      sawSpace = false

    if c == '#':
      l.advance()
      if l.cur == '#':
        l.advance()
        emit(ptHashHash, "##")
      else:
        emit(ptHash, "#")
    elif isIdentStart(c):
      var s = ""
      while not l.atEnd and isIdentCont(l.cur):
        s.add l.cur
        l.advance()
      emit(ptIdent, s)
    elif c.isDigit or (c == '.' and l.peek().isDigit):
      var s = ""
      while not l.atEnd and (l.cur.isAlphaNumeric or l.cur == '.' or
            ((l.cur == '+' or l.cur == '-') and s.len > 0 and
             s[^1] in {'e','E','p','P'})):
        s.add l.cur
        l.advance()
      emit(ptNumber, s)
    elif c == '"':
      var s = "\""
      l.advance()
      while not l.atEnd and l.cur != '"':
        if l.cur == '\\':
          s.add l.cur; l.advance()
          if not l.atEnd: (s.add l.cur; l.advance())
        else:
          s.add l.cur; l.advance()
      if not l.atEnd: (s.add '"'; l.advance())
      emit(ptString, s)
    elif c == '\'':
      var s = "'"
      l.advance()
      while not l.atEnd and l.cur != '\'':
        if l.cur == '\\':
          s.add l.cur; l.advance()
          if not l.atEnd: (s.add l.cur; l.advance())
        else:
          s.add l.cur; l.advance()
      if not l.atEnd: (s.add '\''; l.advance())
      emit(ptChar, s)
    else:
      const multi2 = ["==","!=","<=",">=","&&","||","++","--","->",
                      "+=","-=","*=","/=","%=","&=","|=","^=","<<",">>"]
      var matched = ""
      for m in multi2:
        if l.src.len - l.pos >= 2 and l.src[l.pos ..< l.pos+2] == m:
          matched = m
          break
      if matched.len > 0:
        for _ in 0..<2: l.advance()
        emit(ptPunct, matched)
      else:
        l.advance()
        emit(ptPunct, $c)

  result.add PpToken(kind: ptEOF, text: "", line: l.line, col: l.col,
                      atLineStart: true, spaceBefore: false)
