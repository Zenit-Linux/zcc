import std/strutils
import pp_lexer
import macros

type EvalError* = object of ValueError

proc handleDefined(mt: MacroTable, toks: seq[PpToken], i: var int): int64 =
  ## Obsługuje `defined X` oraz `defined(X)` - musi się wykonać PRZED
  ## ogólną ekspansją makr w #if, bo `defined` to operator preprocesora,
  ## nie makro.
  inc i # 'defined'
  var name: string
  if i < toks.len and toks[i].kind == ptPunct and toks[i].text == "(":
    inc i
    if i >= toks.len or toks[i].kind != ptIdent:
      raise newException(EvalError, "oczekiwano identyfikatora po 'defined('")
    name = toks[i].text
    inc i
    if i >= toks.len or toks[i].text != ")":
      raise newException(EvalError, "brak zamykającego ')' po 'defined('")
    inc i
  else:
    if i >= toks.len or toks[i].kind != ptIdent:
      raise newException(EvalError, "oczekiwano identyfikatora po 'defined'")
    name = toks[i].text
    inc i
  result = if mt.isDefined(name): 1 else: 0

## Preprocessing samego wyrażenia #if: obsłuż `defined` (zanim cokolwiek
## inne się rozwinie), potem rozwiń resztę jako normalne makra, na końcu
## zamień pozostałe niezdefiniowane identyfikatory na literał "0".
proc preprocessIfExpr*(mt: MacroTable, raw: seq[PpToken]): seq[PpToken] =
  var pre: seq[PpToken] = @[]
  var i = 0
  while i < raw.len:
    if raw[i].kind == ptIdent and raw[i].text == "defined":
      let v = handleDefined(mt, raw, i)
      pre.add PpToken(kind: ptNumber, text: $v, line: raw[i-1].line, col: raw[i-1].col)
    else:
      pre.add raw[i]
      inc i

  var activeSet: seq[string] = @[]
  let expanded = expand(mt, pre, activeSet)

  result = @[]
  for t in expanded:
    if t.kind == ptIdent:
      result.add PpToken(kind: ptNumber, text: "0", line: t.line, col: t.col)
    else:
      result.add t

# --- prosty parser wyrażeń (precedence climbing) nad int64 ---

type Parser = object
  toks: seq[PpToken]
  pos: int

proc cur(p: Parser): PpToken =
  if p.pos < p.toks.len: p.toks[p.pos]
  else: PpToken(kind: ptEOF, text: "")

proc advance(p: var Parser) = inc p.pos

proc parseExpr(p: var Parser, minPrec: int): int64

proc parsePrimary(p: var Parser): int64 =
  let t = p.cur
  if t.kind == ptNumber:
    p.advance()
    # obsłuż sufiksy u/U/l/L i prefiksy 0x/0b - uproszczone parsowanie
    var s = t.text
    while s.len > 0 and s[^1] in {'u','U','l','L'}: s.setLen(s.len-1)
    try:
      if s.startsWith("0x") or s.startsWith("0X"):
        result = int64(parseHexInt(s))
      elif s.startsWith("0b") or s.startsWith("0B"):
        result = int64(parseBinInt(s))
      elif s.len > 1 and s[0] == '0':
        result = int64(parseOctInt("0o" & s[1..^1]))
      else:
        result = int64(parseInt(s))
    except ValueError:
      raise newException(EvalError, "niepoprawny literał liczbowy w #if: " & t.text)
  elif t.kind == ptPunct and t.text == "(":
    p.advance()
    result = parseExpr(p, 0)
    if p.cur.kind != ptPunct or p.cur.text != ")":
      raise newException(EvalError, "brak zamykającego ')' w wyrażeniu #if")
    p.advance()
  elif t.kind == ptPunct and t.text == "!":
    p.advance()
    result = if parsePrimary(p) == 0: 1 else: 0
  elif t.kind == ptPunct and t.text == "-":
    p.advance()
    result = -parsePrimary(p)
  elif t.kind == ptPunct and t.text == "~":
    p.advance()
    result = not parsePrimary(p)
  elif t.kind == ptIdent and t.text == "0":
    p.advance()
    result = 0
  else:
    raise newException(EvalError, "nieoczekiwany token w wyrażeniu #if: '" & t.text & "'")

const binOps = [
  ("||", 1), ("&&", 2), ("|", 3), ("^", 4), ("&", 5),
  ("==", 6), ("!=", 6),
  ("<", 7), (">", 7), ("<=", 7), (">=", 7),
  ("<<", 8), (">>", 8),
  ("+", 9), ("-", 9),
  ("*", 10), ("/", 10), ("%", 10)
]

proc precOf(op: string): int =
  for (o, p) in binOps:
    if o == op: return p
  -1

proc applyBin(op: string, a, b: int64): int64 =
  case op
  of "||": (if a != 0 or b != 0: 1 else: 0)
  of "&&": (if a != 0 and b != 0: 1 else: 0)
  of "|": a or b
  of "^": a xor b
  of "&": a and b
  of "==": (if a == b: 1 else: 0)
  of "!=": (if a != b: 1 else: 0)
  of "<": (if a < b: 1 else: 0)
  of ">": (if a > b: 1 else: 0)
  of "<=": (if a <= b: 1 else: 0)
  of ">=": (if a >= b: 1 else: 0)
  of "<<": a shl b
  of ">>": a shr b
  of "+": a + b
  of "-": a - b
  of "*": a * b
  of "/":
    if b == 0: raise newException(EvalError, "dzielenie przez zero w #if")
    a div b
  of "%":
    if b == 0: raise newException(EvalError, "dzielenie przez zero w #if")
    a mod b
  else: raise newException(EvalError, "nieznany operator: " & op)

proc parseExpr(p: var Parser, minPrec: int): int64 =
  var left = parsePrimary(p)
  while true:
    let t = p.cur
    # obsługa trójargumentowego ?: na poziomie precedencji 0 (specjalny przypadek)
    if t.kind == ptPunct and t.text == "?" and minPrec <= 0:
      p.advance()
      let thenVal = parseExpr(p, 0)
      if p.cur.kind != ptPunct or p.cur.text != ":":
        raise newException(EvalError, "brak ':' w wyrażeniu warunkowym #if")
      p.advance()
      let elseVal = parseExpr(p, 0)
      left = if left != 0: thenVal else: elseVal
      continue
    if t.kind != ptPunct: break
    let prec = precOf(t.text)
    if prec < 0 or prec < minPrec: break
    p.advance()
    let right = parseExpr(p, prec + 1)
    left = applyBin(t.text, left, right)
  result = left

proc evalConstExpr*(mt: MacroTable, raw: seq[PpToken]): int64 =
  let toks = preprocessIfExpr(mt, raw)
  var p = Parser(toks: toks, pos: 0)
  if p.toks.len == 0:
    raise newException(EvalError, "puste wyrażenie w #if")
  result = parseExpr(p, 0)
