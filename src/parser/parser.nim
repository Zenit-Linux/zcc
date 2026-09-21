import std/sets
import ../lexer/tokens
import ../diagnostics
import ../options
import ast

type
  Parser* = object
    toks: seq[Token]
    pos: int
    file: string
    std: CStd
    diags*: seq[Diagnostic]
    typedefScopes: seq[HashSet[string]]
    loopDepth: int
    switchDepth: int

proc newParser*(toks: seq[Token], file: string, std: CStd): Parser =
  result = Parser(toks: toks, pos: 0, file: file, std: std, diags: @[],
                   typedefScopes: @[initHashSet[string]()],
                   loopDepth: 0, switchDepth: 0)

# --- prymitywy strumienia tokenów ---

proc cur(p: Parser): Token =
  if p.pos < p.toks.len: p.toks[p.pos]
  else: Token(kind: tkEOF, text: "", line: 0, col: 0, file: p.file)

proc peekTok(p: Parser, off: int): Token =
  let i = p.pos + off
  if i < p.toks.len: p.toks[i]
  else: Token(kind: tkEOF, text: "", line: 0, col: 0, file: p.file)

proc atEnd(p: Parser): bool = p.cur.kind == tkEOF

proc advance(p: var Parser): Token =
  result = p.cur
  if p.pos < p.toks.len: inc p.pos

proc isPunct(t: Token, s: string): bool = t.kind == tkPunct and t.text == s
proc isKw(t: Token, s: string): bool = t.kind == tkKeyword and t.text == s

proc err(p: var Parser, msg: string, suggestion = "") =
  let t = p.cur
  p.diags.add errAt(p.file, t.line, t.col, msg, max(1, t.text.len), suggestion)

proc errAtTok(p: var Parser, t: Token, msg: string, suggestion = "") =
  p.diags.add errAt(p.file, t.line, t.col, msg, max(1, t.text.len), suggestion)

## Konsumuje token-interpunkcję `s`, albo zgłasza błąd i NIE przesuwa
## pozycji (pozwala wołającemu zdecydować o dalszym odzyskiwaniu).
proc expectPunct(p: var Parser, s: string): bool =
  if isPunct(p.cur, s): discard p.advance(); return true
  p.err("oczekiwano '" & s & "', napotkano '" & p.cur.text & "'")
  false

proc expectKw(p: var Parser, s: string): bool =
  if isKw(p.cur, s): discard p.advance(); return true
  p.err("oczekiwano słowa kluczowego '" & s & "', napotkano '" & p.cur.text & "'")
  false

proc expectIdent(p: var Parser): string =
  if p.cur.kind == tkIdent:
    result = p.cur.text
    discard p.advance()
  else:
    p.err("oczekiwano identyfikatora, napotkano '" & p.cur.text & "'")
    result = ""

## Odzyskiwanie po błędzie: pomija tokeny do najbliższego ';' (konsumowanego)
## albo '}' (nie konsumowanego, żeby wołający mógł go poprawnie obsłużyć)
## albo EOF.
proc synchronize(p: var Parser) =
  while not p.atEnd:
    if isPunct(p.cur, ";"):
      discard p.advance()
      return
    if isPunct(p.cur, "}"):
      return
    discard p.advance()

# --- typedef-name tracking (rozwiązanie problemu z punktu 2 w komentarzu modułu) ---

proc pushScope(p: var Parser) = p.typedefScopes.add initHashSet[string]()
proc popScope(p: var Parser) =
  if p.typedefScopes.len > 1: discard p.typedefScopes.pop()

proc declareTypedefName(p: var Parser, name: string) =
  if name.len > 0: p.typedefScopes[^1].incl name

proc isTypedefName(p: Parser, name: string): bool =
  for i in countdown(p.typedefScopes.len - 1, 0):
    if name in p.typedefScopes[i]: return true
  false

# --- pomocnicze: czy bieżący token może zaczynać specyfikator typu? ---

const TypeQualKw = ["const", "volatile", "restrict", "_Atomic"]
const StorageKw = ["typedef", "extern", "static", "auto", "register",
                    "thread_local", "_Thread_local", "constexpr"]
const BaseTypeKw = ["void", "char", "short", "int", "long", "float", "double",
                     "signed", "unsigned", "_Bool", "bool",
                     "struct", "union", "enum"]
const FuncSpecKw = ["inline", "_Noreturn"]

proc startsTypeSpecifier(p: Parser): bool =
  let t = p.cur
  if t.kind != tkKeyword and t.kind != tkIdent: return false
  if t.kind == tkKeyword:
    if t.text in TypeQualKw or t.text in StorageKw or t.text in BaseTypeKw or
       t.text in FuncSpecKw:
      return true
    return false
  # identyfikator: tylko jeśli to znana nazwa typedef
  result = p.isTypedefName(t.text)

# forward declarations
proc parseExpr(p: var Parser): Node
proc parseAssignExpr(p: var Parser): Node
proc parseCastExpr(p: var Parser): Node
proc parseConditionalExpr(p: var Parser): Node
proc parseDeclSpecifiers(p: var Parser): tuple[typ: CType, storage: StorageClass,
                                                 isInline: bool, isNoreturn: bool]
proc parseDeclarator(p: var Parser, base: CType): tuple[name: string, typ: CType,
                                                          params: seq[Node],
                                                          nameTok: Token]
proc parseTypeName(p: var Parser): CType
proc parseStatement(p: var Parser): Node
proc parseCompoundStatement(p: var Parser): Node
proc parseExternalDeclaration(p: var Parser): seq[Node]
proc parseInitializer(p: var Parser): Node
proc startsTypeSpecifierAfterParen(p: var Parser): bool

# ============================== WYRAŻENIA ==============================

proc mkNode(kind: NodeKind, t: Token): Node =
  Node(kind: kind, line: t.line, col: t.col)

proc parsePrimaryExpr(p: var Parser): Node =
  let t = p.cur
  case t.kind
  of tkIntLit:
    discard p.advance()
    return Node(kind: nkIntLit, line: t.line, col: t.col, strVal: t.text)
  of tkFloatLit:
    discard p.advance()
    return Node(kind: nkFloatLit, line: t.line, col: t.col, strVal: t.text)
  of tkCharLit:
    discard p.advance()
    return Node(kind: nkCharLit, line: t.line, col: t.col, strVal: t.text)
  of tkStringLit:
    # sklejanie sąsiadujących literałów stringowych, jak w prawdziwym C:
    # "foo" "bar" == "foobar"
    var s = t.text
    discard p.advance()
    while p.cur.kind == tkStringLit:
      # usuń otaczające cudzysłowy z kolejnego kawałka i dolącz do pierwszego
      let nxt = p.advance().text
      if s.len >= 2 and nxt.len >= 2:
        s = s[0 ..< s.len-1] & nxt[1 ..< nxt.len]
      else:
        s.add nxt
    return Node(kind: nkStringLit, line: t.line, col: t.col, strVal: s)
  of tkIdent:
    discard p.advance()
    return Node(kind: nkIdent, line: t.line, col: t.col, strVal: t.text)
  of tkKeyword:
    if t.text in ["true", "false"]:
      discard p.advance()
      return Node(kind: nkIntLit, line: t.line, col: t.col,
                   strVal: (if t.text == "true": "1" else: "0"))
    if t.text == "nullptr":
      discard p.advance()
      return Node(kind: nkIntLit, line: t.line, col: t.col, strVal: "0")
  else: discard
  if isPunct(t, "("):
    discard p.advance()
    let e = parseExpr(p)
    discard p.expectPunct(")")
    return e
  p.err("oczekiwano wyrażenia, napotkano '" & t.text & "'")
  discard p.advance()
  result = Node(kind: nkIntLit, line: t.line, col: t.col, strVal: "0")

proc parseArgList(p: var Parser): seq[Node] =
  result = @[]
  if isPunct(p.cur, ")"): return
  result.add parseAssignExpr(p)
  while isPunct(p.cur, ","):
    discard p.advance()
    result.add parseAssignExpr(p)

proc parsePostfixExpr(p: var Parser): Node =
  result = parsePrimaryExpr(p)
  while true:
    let t = p.cur
    if isPunct(t, "["):
      discard p.advance()
      let idx = parseExpr(p)
      discard p.expectPunct("]")
      var n = mkNode(nkIndex, t)
      n.a = result; n.b = idx
      result = n
    elif isPunct(t, "("):
      discard p.advance()
      let args = p.parseArgList()
      discard p.expectPunct(")")
      var n = mkNode(nkCall, t)
      n.a = result; n.list = args
      result = n
    elif isPunct(t, "."):
      discard p.advance()
      let fld = p.expectIdent()
      var n = mkNode(nkMember, t)
      n.a = result; n.strVal = fld
      result = n
    elif isPunct(t, "->"):
      discard p.advance()
      let fld = p.expectIdent()
      var n = mkNode(nkArrow, t)
      n.a = result; n.strVal = fld
      result = n
    elif isPunct(t, "++") or isPunct(t, "--"):
      discard p.advance()
      var n = mkNode(nkUnaryPost, t)
      n.op = t.text; n.a = result
      result = n
    else:
      break

const UnaryPrefixOps = ["++", "--", "&", "*", "+", "-", "~", "!"]

## `(` na starcie wyrażenia unarnego może zaczynać cast `(Type)expr` albo
## zwykłe nawiasowane wyrażenie - rozstrzyga to, czy po '(' widać coś, co
## wygląda na nazwę typu.
proc looksLikeCastAhead(p: Parser): bool =
  if not isPunct(p.cur, "("): return false
  let saved = p.pos
  var pp = p
  discard pp.advance()
  result = pp.startsTypeSpecifier()

proc parseUnaryExpr(p: var Parser): Node =
  let t = p.cur
  if t.kind == tkKeyword and t.text == "sizeof":
    discard p.advance()
    if isPunct(p.cur, "(") and (block:
        let saved = p.pos
        discard p.advance()
        let isTy = p.startsTypeSpecifier()
        p.pos = saved
        isTy):
      discard p.advance()  # '('
      let ty = parseTypeName(p)
      discard p.expectPunct(")")
      var n = mkNode(nkSizeofType, t)
      n.typ = ty
      return n
    else:
      var n = mkNode(nkSizeofExpr, t)
      n.a = parseUnaryExpr(p)
      return n
  if t.kind == tkKeyword and t.text in ["_Alignof", "alignof"]:
    discard p.advance()
    discard p.expectPunct("(")
    let ty = parseTypeName(p)
    discard p.expectPunct(")")
    var n = mkNode(nkSizeofType, t)
    n.typ = ty
    return n
  if t.kind == tkPunct and t.text in UnaryPrefixOps:
    discard p.advance()
    var n = mkNode(nkUnaryPre, t)
    n.op = t.text
    n.a = parseCastExpr(p)
    return n
  result = parsePostfixExpr(p)

proc parseCastExpr(p: var Parser): Node =
  if p.looksLikeCastAhead():
    let t = p.cur
    let saved = p.pos
    discard p.advance()  # '('
    let ty = parseTypeName(p)
    if isPunct(p.cur, ")"):
      discard p.advance()
      # Literał złożony `(Type){...}` (C99) - rozpoznajemy składniowo,
      # ale traktujemy ciało jak zwykłą listę inicjalizatorów przypiętą
      # do cast-node (uproszczenie - pełne modelowanie w sema to TODO).
      var n = mkNode(nkCast, t)
      n.typ = ty
      n.a = parseCastExpr(p)
      return n
    else:
      # nie był to jednak poprawny cast - cofnij się i sparsuj jako zwykłe wyrażenie
      p.pos = saved
  result = parseUnaryExpr(p)

proc parseBinaryLevel(p: var Parser, ops: openArray[string],
                       nextLevel: proc(p: var Parser): Node): Node =
  result = nextLevel(p)
  while p.cur.kind == tkPunct and p.cur.text in ops:
    let t = p.advance()
    var n = mkNode(nkBinary, t)
    n.op = t.text
    n.a = result
    n.b = nextLevel(p)
    result = n

proc parseMultiplicative(p: var Parser): Node =
  parseBinaryLevel(p, ["*", "/", "%"], parseCastExpr)
proc parseAdditive(p: var Parser): Node =
  parseBinaryLevel(p, ["+", "-"], parseMultiplicative)
proc parseShift(p: var Parser): Node =
  parseBinaryLevel(p, ["<<", ">>"], parseAdditive)
proc parseRelational(p: var Parser): Node =
  parseBinaryLevel(p, ["<", ">", "<=", ">="], parseShift)
proc parseEquality(p: var Parser): Node =
  parseBinaryLevel(p, ["==", "!="], parseRelational)
proc parseBitAnd(p: var Parser): Node =
  parseBinaryLevel(p, ["&"], parseEquality)
proc parseBitXor(p: var Parser): Node =
  parseBinaryLevel(p, ["^"], parseBitAnd)
proc parseBitOr(p: var Parser): Node =
  parseBinaryLevel(p, ["|"], parseBitXor)
proc parseLogicalAnd(p: var Parser): Node =
  parseBinaryLevel(p, ["&&"], parseBitOr)
proc parseLogicalOr(p: var Parser): Node =
  parseBinaryLevel(p, ["||"], parseLogicalAnd)

proc parseConditionalExpr(p: var Parser): Node =
  result = parseLogicalOr(p)
  if isPunct(p.cur, "?"):
    let t = p.advance()
    let thenE = parseExpr(p)
    discard p.expectPunct(":")
    let elseE = parseConditionalExpr(p)
    var n = mkNode(nkCond, t)
    n.a = result; n.b = thenE; n.c = elseE
    result = n

const AssignOps = ["=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>="]

proc parseAssignExpr(p: var Parser): Node =
  # LL(k) bez pełnego rozdzielenia unary/conditional - w praktyce liberalne
  # przyjęcie: parsujemy conditional-expr, a jeśli po nim jest operator
  # przypisania, reinterpretujemy lewą stronę jako l-wartość (parser jej
  # nie waliduje - to zadanie sema).
  result = parseConditionalExpr(p)
  if p.cur.kind == tkPunct and p.cur.text in AssignOps:
    let t = p.advance()
    var n = mkNode(nkAssign, t)
    n.op = t.text
    n.a = result
    n.b = parseAssignExpr(p)   # prawostronnie łączne
    result = n

proc parseExpr(p: var Parser): Node =
  result = parseAssignExpr(p)
  if isPunct(p.cur, ","):
    var n = Node(kind: nkComma, line: result.line, col: result.col, list: @[result])
    while isPunct(p.cur, ","):
      discard p.advance()
      n.list.add parseAssignExpr(p)
    result = n

## Inicjalizator: albo zwykłe assignment-expression, albo lista `{ ... }`
## (rekurencyjnie - obsługuje zagnieżdżone inicjalizatory tablic/struktur).
## Designated initializers (C99 `.pole = ...` / `[i] = ...`) rozpoznawane
## składniowo i pomijane bez interpretacji projekcji (TODO: sema).
proc parseInitializer(p: var Parser): Node =
  if isPunct(p.cur, "{"):
    let t = p.advance()
    var n = mkNode(nkInitList, t)
    if not isPunct(p.cur, "}"):
      while true:
        # designator: .field = / [expr] =  - pomijamy sam designator,
        # zachowujemy wyrażenie/pod-inicjalizator
        while isPunct(p.cur, ".") or isPunct(p.cur, "["):
          if isPunct(p.cur, "."):
            discard p.advance()
            discard p.expectIdent()
          else:
            discard p.advance()
            discard parseExpr(p)
            discard p.expectPunct("]")
        if isPunct(p.cur, "="):
          discard p.advance()
        n.list.add parseInitializer(p)
        if isPunct(p.cur, ","):
          discard p.advance()
          if isPunct(p.cur, "}"): break
        else:
          break
    discard p.expectPunct("}")
    return n
  result = parseAssignExpr(p)

# ============================== TYPY ==============================

type SpecAccum = object
  voidC, boolC, charC, intC, floatC, doubleC: int
  shortC, longC, signedC, unsignedC: int
  structOrUnionOrEnum: CType
  typedefRef: CType
  sawAny: bool

proc parseEnumSpecifier(p: var Parser): CType =
  let kwTok = p.advance()  # 'enum'
  var tag = ""
  if p.cur.kind == tkIdent:
    tag = p.advance().text
  var t = CType(kind: tkEnum, tag: tag, isComplete: false)
  if isPunct(p.cur, "{"):
    discard p.advance()
    t.isComplete = true
    while not isPunct(p.cur, "}") and not p.atEnd:
      let nameTok = p.cur
      let name = p.expectIdent()
      var valExpr: Node = nil
      if isPunct(p.cur, "="):
        discard p.advance()
        valExpr = parseConditionalExpr(p)
      t.enumerators.add Enumerator(name: name, value: valExpr,
                                    line: nameTok.line, col: nameTok.col)
      if isPunct(p.cur, ","):
        discard p.advance()
      else:
        break
    discard p.expectPunct("}")
  elif tag.len == 0:
    p.errAtTok(kwTok, "oczekiwano tagu albo ciała '{...}' po 'enum'")
  result = t

proc parseStructOrUnionSpecifier(p: var Parser): CType =
  let kindTok = p.advance()  # 'struct' albo 'union'
  let kind = if kindTok.text == "struct": tkStruct else: tkUnion
  var tag = ""
  if p.cur.kind == tkIdent:
    tag = p.advance().text
  var t = CType(kind: kind, tag: tag, isComplete: false)
  if isPunct(p.cur, "{"):
    discard p.advance()
    t.isComplete = true
    while not isPunct(p.cur, "}") and not p.atEnd:
      if isKw(p.cur, "_Static_assert") or isKw(p.cur, "static_assert"):
        discard p.advance(); discard p.expectPunct("(")
        discard parseConditionalExpr(p)
        if isPunct(p.cur, ","):
          discard p.advance(); discard parseAssignExpr(p)
        discard p.expectPunct(")"); discard p.expectPunct(";")
        continue
      let (baseTy, _, _, _) = parseDeclSpecifiers(p)
      if baseTy.isNil:
        p.err("oczekiwano specyfikatora typu w deklaracji pola")
        p.synchronize()
        continue
      # obsługa listy deklaratorów pól (w tym bitfieldów) oddzielonych przecinkiem
      while true:
        var fname = ""
        var fty = baseTy
        var lineTok = p.cur
        if not isPunct(p.cur, ":"):
          let d = parseDeclarator(p, baseTy)
          fname = d.name; fty = d.typ; lineTok = d.nameTok
        var bitW: Node = nil
        if isPunct(p.cur, ":"):
          discard p.advance()
          bitW = parseConditionalExpr(p)
        t.fields.add Field(name: fname, typ: fty, bitWidth: bitW,
                            line: lineTok.line, col: lineTok.col)
        if isPunct(p.cur, ","):
          discard p.advance()
        else:
          break
      discard p.expectPunct(";")
    discard p.expectPunct("}")
  elif tag.len == 0:
    p.errAtTok(kindTok, "oczekiwano tagu albo ciała '{...}' po '" & kindTok.text & "'")
  result = t

## Zjada ciąg specyfikatorów deklaracji (storage-class, qualifiers,
## type-specifiers, function-specifiers) w dowolnej kolejności (tak jak
## dopuszcza C: `static const unsigned long int x` == `const static long
## unsigned x` itd.) i składa je w jeden CType. Zwraca (nil, ...) jeśli
## nie napotkano ŻADNEGO specyfikatora (czyli to nie jest deklaracja).
proc parseDeclSpecifiers(p: var Parser): tuple[typ: CType, storage: StorageClass,
                                                 isInline: bool, isNoreturn: bool] =
  var acc: SpecAccum
  var storage = scNone
  var isConst = false
  var isVolatile = false
  var isInline = false
  var isNoreturn = false
  var sawStorage = false

  while true:
    let t = p.cur
    if t.kind == tkKeyword and t.text in StorageKw:
      acc.sawAny = true
      case t.text
      of "typedef": storage = scTypedef
      of "extern": storage = scExtern
      of "static": storage = scStatic
      of "auto": storage = scAuto
      of "register": storage = scRegister
      else: discard  # thread_local/constexpr: uznane składniowo, nie modelowane głębiej (TODO)
      sawStorage = true
      discard p.advance()
    elif t.kind == tkKeyword and t.text in TypeQualKw:
      acc.sawAny = true
      if t.text == "const": isConst = true
      elif t.text == "volatile": isVolatile = true
      discard p.advance()  # restrict/_Atomic: przyjęte, nie modelowane osobno (TODO)
    elif t.kind == tkKeyword and t.text in FuncSpecKw:
      acc.sawAny = true
      if t.text == "inline": isInline = true
      else: isNoreturn = true
      discard p.advance()
    elif t.kind == tkKeyword and t.text == "void":
      acc.sawAny = true; inc acc.voidC; discard p.advance()
    elif t.kind == tkKeyword and t.text in ["_Bool", "bool"]:
      acc.sawAny = true; inc acc.boolC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "char":
      acc.sawAny = true; inc acc.charC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "short":
      acc.sawAny = true; inc acc.shortC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "int":
      acc.sawAny = true; inc acc.intC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "long":
      acc.sawAny = true; inc acc.longC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "float":
      acc.sawAny = true; inc acc.floatC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "double":
      acc.sawAny = true; inc acc.doubleC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "signed":
      acc.sawAny = true; inc acc.signedC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "unsigned":
      acc.sawAny = true; inc acc.unsignedC; discard p.advance()
    elif t.kind == tkKeyword and t.text == "struct" or (t.kind == tkKeyword and t.text == "union"):
      acc.sawAny = true
      acc.structOrUnionOrEnum = parseStructOrUnionSpecifier(p)
    elif t.kind == tkKeyword and t.text == "enum":
      acc.sawAny = true
      acc.structOrUnionOrEnum = parseEnumSpecifier(p)
    elif t.kind == tkIdent and p.isTypedefName(t.text) and acc.typedefRef.isNil and
         acc.voidC == 0 and acc.boolC == 0 and acc.charC == 0 and acc.intC == 0 and
         acc.longC == 0 and acc.shortC == 0 and acc.floatC == 0 and acc.doubleC == 0 and
         acc.structOrUnionOrEnum.isNil:
      acc.sawAny = true
      acc.typedefRef = CType(kind: tkTypedefName, tag: t.text, isComplete: true)
      discard p.advance()
    else:
      break

  if not acc.sawAny:
    return (nil, scNone, false, false)

  var base: CType
  if not acc.structOrUnionOrEnum.isNil:
    base = acc.structOrUnionOrEnum
  elif not acc.typedefRef.isNil:
    base = acc.typedefRef
  elif acc.voidC > 0:
    base = ctype(tkVoid)
  elif acc.boolC > 0:
    base = ctype(tkBool)
  elif acc.charC > 0:
    base = ctype(tkChar, acc.unsignedC > 0)
  elif acc.floatC > 0:
    base = ctype(tkFloat)
  elif acc.doubleC > 0:
    base = ctype(if acc.longC > 0: tkLongDouble else: tkDouble)
  elif acc.longC >= 2:
    base = ctype(tkLongLong, acc.unsignedC > 0)
  elif acc.longC == 1:
    base = ctype(tkLong, acc.unsignedC > 0)
  elif acc.shortC > 0:
    base = ctype(tkShort, acc.unsignedC > 0)
  elif acc.intC > 0 or acc.signedC > 0 or acc.unsignedC > 0:
    base = ctype(tkInt, acc.unsignedC > 0)
  elif sawStorage or isConst or isVolatile or isInline or isNoreturn:
    # np. samo "static" bez specyfikatora typu - C89 domniemywał `int`,
    # nowoczesne standardy tego zabraniają; zgłaszamy i naprawczo zakładamy int
    p.err("brak specyfikatora typu w deklaracji - zakładam 'int' (niezgodne z C99+)")
    base = ctype(tkInt)
  else:
    base = ctype(tkInt)

  base.isConst = isConst
  base.isVolatile = isVolatile
  result = (base, storage, isInline, isNoreturn)

## Parsuje listę parametrów (bez otaczających nawiasów - te konsumuje wołający).
## Zwraca typy (do CType.paramTypes), nazwane węzły (do Node.params, do AST)
## i informację o wariadyczności.
proc parseParamList(p: var Parser): tuple[types: seq[CType], nodes: seq[Node],
                                            variadic: bool, known: bool] =
  result.types = @[]; result.nodes = @[]; result.variadic = false; result.known = true
  if isPunct(p.cur, ")"):
    result.known = false  # `()` - brak jawnej listy (styl K&R / nieznane)
    return
  if isKw(p.cur, "void") and isPunct(peekTok(p, 1), ")"):
    discard p.advance()
    return  # `(void)` - jawnie zero parametrów
  while true:
    if isPunct(p.cur, "..."):
      discard p.advance()
      result.variadic = true
      break
    let (baseTy, storage, _, _) = parseDeclSpecifiers(p)
    if baseTy.isNil:
      p.err("oczekiwano specyfikatora typu parametru")
      break
    let d = parseDeclarator(p, baseTy)
    result.types.add d.typ
    var pn = Node(kind: nkVarDecl, line: d.nameTok.line, col: d.nameTok.col,
                   strVal: d.name, typ: d.typ, storage: storage)
    result.nodes.add pn
    if isPunct(p.cur, ","):
      discard p.advance()
    else:
      break

type DeclChain = object
  name: string
  nameTok: Token
  build: proc(base: CType): CType {.closure.}
  params: seq[Node]
  paramsKnown: bool
  isFunction: bool
  isVariadic: bool

proc identityChain(nameTok: Token): DeclChain =
  DeclChain(name: "", nameTok: nameTok,
            build: proc(base: CType): CType = base,
            params: @[], paramsKnown: true, isFunction: false, isVariadic: false)

proc parseDirectDeclaratorChain(p: var Parser): DeclChain

proc parsePointerPrefix(p: var Parser): seq[proc(t: CType): CType {.closure.}] =
  result = @[]
  while isPunct(p.cur, "*"):
    discard p.advance()
    var isConst = false
    var isVolatile = false
    while p.cur.kind == tkKeyword and p.cur.text in TypeQualKw:
      if p.cur.text == "const": isConst = true
      elif p.cur.text == "volatile": isVolatile = true
      discard p.advance()
    let c = isConst
    let v = isVolatile
    result.add proc(t: CType): CType =
      var pt = pointerTo(t)
      pt.isConst = c
      pt.isVolatile = v
      pt

## UWAGA (bug historyczny naprawiony tutaj, zostawiam komentarz jako
## przestrogę): wskaźnik prefiksowy przy deklaratorze NIE wrapuje wyniku
## direct-declaratora - wrapuje BAZOWY typ, który dopiero potem wchodzi
## w sufiksy direct-declaratora. Różnica jest kluczowa, gdy direct-
## -declarator kończy się sufiksem funkcyjnym/tablicowym: `char
## *f(int)` to "funkcja zwracająca wskaźnik do char", NIE "wskaźnik do
## funkcji zwracającej char" (to drugie wymaga JAWNYCH nawiasów:
## `char (*f)(int)`). Pierwsza (błędna) wersja tej funkcji robiła
## `ptr(inner.build(base))` - co dawało poprawny wynik dla przypadków
## z nawiasami (bo tam "beforeSuffixes" w parseDirectDeclaratorChain i
## tak poprawnie wrapuje NA ZEWNĄTRZ sufiksów), ale łamało dokładnie ten
## bardzo częsty idiom bez nawiasów. Poprawka: `inner.build(ptr(base))` -
## wskaźnik modyfikuje to, co "widzi" direct-declarator jako swój typ
## bazowy, a nie to, co direct-declarator już zbudował.
proc parseDeclaratorChain(p: var Parser): DeclChain =
  let ptrBuilds = parsePointerPrefix(p)
  let inner = parseDirectDeclaratorChain(p)
  result = inner
  if ptrBuilds.len > 0:
    let innerBuild = inner.build
    result.build = proc(base: CType): CType =
      var wrapped = base
      for i in countdown(ptrBuilds.len - 1, 0):
        wrapped = ptrBuilds[i](wrapped)
      innerBuild(wrapped)

proc parseDirectDeclaratorChain(p: var Parser): DeclChain =
  var name = ""
  var nameTok = p.cur
  var beforeSuffixes: proc(base: CType): CType {.closure.}
  if isPunct(p.cur, "("):
    # Może być: (a) deklarator zagnieżdżony ( *p ) / ( f ) dla spirali,
    # albo (b) po prostu lista parametrów jeśli to, co poza tym, to
    # abstrakcyjny deklarator (np. w typie parametru funkcji wyższego
    # rzędu). Heurystyka: jeśli zaraz po '(' jest coś co wygląda na
    # specyfikator typu albo ')' - to lista parametrów abstrakcyjnego
    # deklaratora funkcji, NIE zagnieżdżony deklarator.
    if p.startsTypeSpecifierAfterParen():
      beforeSuffixes = proc(base: CType): CType = base
    else:
      discard p.advance()  # '('
      let inner = parseDeclaratorChain(p)
      discard p.expectPunct(")")
      name = inner.name
      nameTok = inner.nameTok
      beforeSuffixes = inner.build
  elif p.cur.kind == tkIdent:
    name = p.advance().text
    beforeSuffixes = proc(base: CType): CType = base
  else:
    beforeSuffixes = proc(base: CType): CType = base

  var suffixOps: seq[proc(t: CType): CType {.closure.}] = @[]
  var paramsOut: seq[Node] = @[]
  var isFn = false
  var isVariadic = false
  var paramsKnown = true
  while true:
    if isPunct(p.cur, "["):
      discard p.advance()
      var sizeExpr: Node = nil
      # type-qualifiers wewnątrz [] (np. `int a[static 10]`, `[const]`)
      # - dopuszczone składniowo, pomijane semantycznie (TODO)
      while p.cur.kind == tkKeyword and (p.cur.text in TypeQualKw or p.cur.text == "static"):
        discard p.advance()
      if not isPunct(p.cur, "]"):
        sizeExpr = parseAssignExpr(p)
      discard p.expectPunct("]")
      let se = sizeExpr
      suffixOps.add proc(t: CType): CType =
        CType(kind: tkArray, elem: t, arrayLen: se, isComplete: se != nil, hasKnownParams: true)
    elif isPunct(p.cur, "("):
      discard p.advance()
      let pr = parseParamList(p)
      discard p.expectPunct(")")
      isFn = true
      paramsOut = pr.nodes
      isVariadic = pr.variadic
      paramsKnown = pr.known
      let ptypes = pr.types
      let variadic = pr.variadic
      let known = pr.known
      suffixOps.add proc(t: CType): CType =
        CType(kind: tkFunction, returnType: t, paramTypes: ptypes,
              isVariadic: variadic, hasKnownParams: known, isComplete: true)
    else:
      break

  result = DeclChain(name: name, nameTok: nameTok, params: paramsOut,
                      paramsKnown: paramsKnown, isFunction: isFn, isVariadic: isVariadic)
  result.build = proc(base: CType): CType =
    var t = base
    for i in countdown(suffixOps.len - 1, 0):
      t = suffixOps[i](t)
    beforeSuffixes(t)

proc parseDeclarator(p: var Parser, base: CType): tuple[name: string, typ: CType,
                                                          params: seq[Node],
                                                          nameTok: Token] =
  let chain = parseDeclaratorChain(p)
  result = (chain.name, chain.build(base), chain.params, chain.nameTok)

## Typ w kontekście bez nazwy (cast, sizeof, parametr bez nazwy): specyfikatory
## + opcjonalny deklarator abstrakcyjny (bez identyfikatora).
proc parseTypeName(p: var Parser): CType =
  let (baseTy, _, _, _) = parseDeclSpecifiers(p)
  if baseTy.isNil:
    p.err("oczekiwano nazwy typu")
    return tyErrorC()
  let chain = parseDeclaratorChain(p)
  result = chain.build(baseTy)

# potrzebne forward-refy dla helperów użytych wyżej zanim zostały zdefiniowane
proc startsTypeSpecifierAfterParen(p: var Parser): bool =
  ## Podgląda token PO bieżącym '(' bez konsumowania - używane w
  ## parseDirectDeclaratorChain do odróżnienia `(*p)` (zagnieżdżony
  ## deklarator) od `(int, int)` (lista parametrów abstrakcyjnego
  ## deklaratora funkcji).
  let nxt = peekTok(p, 1)
  if isPunct(nxt, ")"): return true  # `()` traktujemy jak listę parametrów
  if nxt.kind == tkKeyword and (nxt.text in TypeQualKw or nxt.text in StorageKw or
                                  nxt.text in BaseTypeKw or nxt.text in FuncSpecKw):
    return true
  if nxt.kind == tkIdent and p.isTypedefName(nxt.text): return true
  false

# ============================== INSTRUKCJE ==============================

proc parseLocalDeclStmt(p: var Parser): Node

proc isDeclarationStart(p: Parser): bool = p.startsTypeSpecifier()

proc parseIfStmt(p: var Parser): Node =
  let t = p.advance()  # 'if'
  discard p.expectPunct("(")
  let cond = parseExpr(p)
  discard p.expectPunct(")")
  let thenS = parseStatement(p)
  var elseS: Node = nil
  if isKw(p.cur, "else"):
    discard p.advance()
    elseS = parseStatement(p)
  result = mkNode(nkIf, t)
  result.a = cond; result.b = thenS; result.c = elseS

proc parseWhileStmt(p: var Parser): Node =
  let t = p.advance()
  discard p.expectPunct("(")
  let cond = parseExpr(p)
  discard p.expectPunct(")")
  inc p.loopDepth
  let body = parseStatement(p)
  dec p.loopDepth
  result = mkNode(nkWhile, t)
  result.a = cond; result.b = body

proc parseDoWhileStmt(p: var Parser): Node =
  let t = p.advance()  # 'do'
  inc p.loopDepth
  let body = parseStatement(p)
  dec p.loopDepth
  discard p.expectKw("while")
  discard p.expectPunct("(")
  let cond = parseExpr(p)
  discard p.expectPunct(")")
  discard p.expectPunct(";")
  result = mkNode(nkDoWhile, t)
  result.a = cond; result.b = body

proc parseForStmt(p: var Parser): Node =
  let t = p.advance()  # 'for'
  discard p.expectPunct("(")
  p.pushScope()
  var initN: Node = nil
  if isPunct(p.cur, ";"):
    discard p.advance()
  elif p.isDeclarationStart():
    initN = parseLocalDeclStmt(p)  # konsumuje końcowy ';'
  else:
    initN = Node(kind: nkExprStmt, line: p.cur.line, col: p.cur.col, a: parseExpr(p))
    discard p.expectPunct(";")
  var condN: Node = nil
  if not isPunct(p.cur, ";"): condN = parseExpr(p)
  discard p.expectPunct(";")
  var postN: Node = nil
  if not isPunct(p.cur, ")"): postN = parseExpr(p)
  discard p.expectPunct(")")
  inc p.loopDepth
  let body = parseStatement(p)
  dec p.loopDepth
  p.popScope()
  result = mkNode(nkFor, t)
  result.a = initN; result.b = condN; result.c = postN; result.d = body

proc parseReturnStmt(p: var Parser): Node =
  let t = p.advance()
  result = mkNode(nkReturnStmt, t)
  if not isPunct(p.cur, ";"):
    result.a = parseExpr(p)
  discard p.expectPunct(";")

proc parseSwitchStmt(p: var Parser): Node =
  let t = p.advance()
  discard p.expectPunct("(")
  let e = parseExpr(p)
  discard p.expectPunct(")")
  inc p.switchDepth
  let body = parseStatement(p)
  dec p.switchDepth
  result = mkNode(nkSwitchStmt, t)
  result.a = e; result.b = body

proc parseStatement(p: var Parser): Node =
  let t = p.cur
  if isPunct(t, "{"):
    return parseCompoundStatement(p)
  if isPunct(t, ";"):
    discard p.advance()
    return mkNode(nkEmptyStmt, t)
  if t.kind == tkKeyword:
    case t.text
    of "if": return parseIfStmt(p)
    of "while": return parseWhileStmt(p)
    of "do": return parseDoWhileStmt(p)
    of "for": return parseForStmt(p)
    of "return": return parseReturnStmt(p)
    of "break":
      discard p.advance()
      if p.loopDepth == 0 and p.switchDepth == 0:
        p.errAtTok(t, "'break' poza pętlą lub switch")
      discard p.expectPunct(";")
      return mkNode(nkBreakStmt, t)
    of "continue":
      discard p.advance()
      if p.loopDepth == 0:
        p.errAtTok(t, "'continue' poza pętlą")
      discard p.expectPunct(";")
      return mkNode(nkContinueStmt, t)
    of "goto":
      discard p.advance()
      let lbl = p.expectIdent()
      discard p.expectPunct(";")
      var n = mkNode(nkGotoStmt, t)
      n.strVal = lbl
      return n
    of "switch": return parseSwitchStmt(p)
    of "case":
      discard p.advance()
      let e = parseConditionalExpr(p)
      discard p.expectPunct(":")
      if p.switchDepth == 0:
        p.errAtTok(t, "'case' poza switch")
      var n = mkNode(nkCaseStmt, t)
      n.a = e
      n.b = parseStatement(p)
      return n
    of "default":
      discard p.advance()
      discard p.expectPunct(":")
      if p.switchDepth == 0:
        p.errAtTok(t, "'default' poza switch")
      var n = mkNode(nkDefaultStmt, t)
      n.a = parseStatement(p)
      return n
    of "_Static_assert", "static_assert":
      discard p.advance()
      discard p.expectPunct("(")
      let cond = parseConditionalExpr(p)
      var msg = ""
      if isPunct(p.cur, ","):
        discard p.advance()
        msg = p.cur.text
        discard p.advance()
      discard p.expectPunct(")")
      discard p.expectPunct(";")
      var n = mkNode(nkStaticAssert, t)
      n.a = cond; n.strVal = msg
      return n
    else: discard
  # etykieta: `ident ':' statement` - trzeba odróżnić od wyrażenia
  # zaczynającego się identyfikatorem (np. wywołania funkcji) - podgląd 1 tokenu
  if t.kind == tkIdent and isPunct(peekTok(p, 1), ":") and
     not (peekTok(p, 1).kind == tkPunct and peekTok(p, 1).text == "::"):
    discard p.advance(); discard p.advance()
    var n = mkNode(nkLabelStmt, t)
    n.strVal = t.text
    n.a = parseStatement(p)
    return n
  if p.isDeclarationStart():
    return parseLocalDeclStmt(p)
  # instrukcja-wyrażenie
  let e = parseExpr(p)
  discard p.expectPunct(";")
  result = Node(kind: nkExprStmt, line: t.line, col: t.col, a: e)

## Jedna deklaracja lokalna `specyfikatory deklarator[=init][, deklarator...] ;`
## - może zawierać kilka nazw naraz (`int a, *b = 0, c[3];`), stąd zwraca
## nkDeclStmt opakowujący listę nkVarDecl. Obsługuje też `typedef` lokalny.
proc parseLocalDeclStmt(p: var Parser): Node =
  let startTok = p.cur
  let (baseTy, storage, isInline, isNoreturn) = parseDeclSpecifiers(p)
  result = mkNode(nkDeclStmt, startTok)
  if baseTy.isNil:
    p.err("oczekiwano deklaracji")
    p.synchronize()
    return
  if isPunct(p.cur, ";"):
    # sama deklaracja typu bez zmiennej, np. `struct Foo { ... };` wewnątrz funkcji
    discard p.advance()
    var n = mkNode(nkTagDecl, startTok)
    n.typ = baseTy
    result.list.add n
    return
  while true:
    let d = parseDeclarator(p, baseTy)
    if storage == scTypedef:
      p.declareTypedefName(d.name)
      var n = mkNode(nkTypedefDecl, d.nameTok)
      n.strVal = d.name; n.typ = d.typ
      result.list.add n
    else:
      var n = mkNode(nkVarDecl, d.nameTok)
      n.strVal = d.name; n.typ = d.typ; n.storage = storage
      n.isInline = isInline; n.isNoreturn = isNoreturn
      if isPunct(p.cur, "="):
        discard p.advance()
        n.a = parseInitializer(p)
      result.list.add n
    if isPunct(p.cur, ","):
      discard p.advance()
    else:
      break
  discard p.expectPunct(";")

proc parseCompoundStatement(p: var Parser): Node =
  let t = p.advance()  # '{'
  p.pushScope()
  result = mkNode(nkCompound, t)
  while not isPunct(p.cur, "}") and not p.atEnd:
    let before = p.pos
    result.list.add parseStatement(p)
    if p.pos == before:
      # zabezpieczenie przed nieskończoną pętlą przy nieznanym tokenie
      p.err("nieoczekiwany token '" & p.cur.text & "'")
      discard p.advance()
  discard p.expectPunct("}")
  p.popScope()

# ============================== DEKLARACJE TOP-LEVEL ==============================

## Jedna "external declaration" wg gramatyki C - może rozwinąć się w kilka
## węzłów top-level (deklaracja wielu zmiennych naraz), stąd `seq[Node]`.
proc parseExternalDeclaration(p: var Parser): seq[Node] =
  result = @[]
  let startTok = p.cur

  if isKw(p.cur, "_Static_assert") or isKw(p.cur, "static_assert"):
    discard p.advance()
    discard p.expectPunct("(")
    let cond = parseConditionalExpr(p)
    var msg = ""
    if isPunct(p.cur, ","):
      discard p.advance()
      msg = p.cur.text
      discard p.advance()
    discard p.expectPunct(")")
    discard p.expectPunct(";")
    var n = mkNode(nkStaticAssert, startTok)
    n.a = cond; n.strVal = msg
    result.add n
    return

  let (baseTy, storage, isInline, isNoreturn) = parseDeclSpecifiers(p)
  if baseTy.isNil:
    p.err("oczekiwano deklaracji na poziomie pliku, napotkano '" & p.cur.text & "'")
    p.synchronize()
    return

  if isPunct(p.cur, ";"):
    # sama deklaracja tagu: `struct Foo { ... };`
    discard p.advance()
    var n = mkNode(nkTagDecl, startTok)
    n.typ = baseTy
    result.add n
    return

  while true:
    let d = parseDeclarator(p, baseTy)

    if storage == scTypedef:
      p.declareTypedefName(d.name)
      var n = mkNode(nkTypedefDecl, d.nameTok)
      n.strVal = d.name; n.typ = d.typ
      result.add n
    elif d.typ.kind == tkFunction and isPunct(p.cur, "{"):
      # definicja funkcji - tylko jeśli to JEDYNY deklarator w tej external-declaration
      var n = mkNode(nkFuncDef, d.nameTok)
      n.strVal = d.name; n.typ = d.typ; n.storage = storage
      n.isInline = isInline; n.isNoreturn = isNoreturn
      n.params = d.params
      p.pushScope()
      for prm in d.params:
        if prm.typ.kind == tkTypedefName: discard  # nazwy parametrów nie są typami
      n.b = parseCompoundStatement(p)
      result.add n
      return   # ciało funkcji kończy całą external-declaration
    else:
      if d.typ.kind == tkFunction:
        var n = mkNode(nkFuncDecl, d.nameTok)
        n.strVal = d.name; n.typ = d.typ; n.storage = storage
        n.isInline = isInline; n.isNoreturn = isNoreturn
        n.params = d.params
        result.add n
      else:
        var n = mkNode(nkVarDecl, d.nameTok)
        n.strVal = d.name; n.typ = d.typ; n.storage = storage
        if isPunct(p.cur, "="):
          discard p.advance()
          n.a = parseInitializer(p)
        result.add n
    if isPunct(p.cur, ","):
      discard p.advance()
    else:
      break
  discard p.expectPunct(";")

proc parseTranslationUnit*(p: var Parser): Node =
  result = Node(kind: nkTranslationUnit, line: 1, col: 1, list: @[])
  while not p.atEnd:
    let before = p.pos
    let decls = parseExternalDeclaration(p)
    result.list.add decls
    if p.pos == before:
      # nic nie skonsumowano (np. skrajnie zniekształcony wejściowy token) -
      # wymuszamy postęp, żeby uniknąć zawieszenia parsera
      p.err("nieoczekiwany token na poziomie pliku: '" & p.cur.text & "'")
      discard p.advance()
      p.synchronize()

## Punkt wejścia wygodny dla main.nim: tokeny -> AST + zebrane diagnostyki.
proc parseTokens*(toks: seq[Token], file: string, std: CStd): tuple[unit: Node, diags: seq[Diagnostic]] =
  var p = newParser(toks, file, std)
  let unit = parseTranslationUnit(p)
  result = (unit, p.diags)
