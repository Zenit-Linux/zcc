import std/[tables, strutils, sets]
import ../parser/ast
import ../diagnostics
import layout

type
  LocalVar = tuple[offset: int, typ: CType]

  SymKind = enum siLocal, siGlobal, siFunc, siEnumConst, siUnknown
  SymInfo = object
    kind: SymKind
    offset: int
    typ: CType

  CGCtx = object
    file: string
    diags: seq[Diagnostic]
    hadError: bool

    outp: string       # .text (kod bieżąco generowany - patrz genFunction, bufor podmieniany na czas funkcji)
    dataOut: string     # .data
    bssOut: string        # .bss
    rodataOut: string      # .rodata (pula literałów string)

    funcSigs: Table[string, CType]
    globalVars: Table[string, CType]
    enumConsts: Table[string, int64]
    caseLabels: Table[pointer, string]  # nkCaseStmt/nkDefaultStmt (adres węzła) -> etykieta

    strCounter: int
    labelCounter: int

    scopes: seq[Table[string, LocalVar]]
    frameUsed: int
    curFuncName: string
    curRetType: CType
    epilogueLabel: string
    pushDepth: int
    breakLabels: seq[string]
    continueLabels: seq[string]

# ============================== prymitywy emisji ==============================

proc newLabel(ctx: var CGCtx): string =
  result = ".Lz" & $ctx.labelCounter
  inc ctx.labelCounter

proc userLabel(ctx: CGCtx, name: string): string =
  ".Luser_" & ctx.curFuncName & "_" & name

proc emit(ctx: var CGCtx, s: string) =
  ctx.outp.add "    " & s & "\n"

proc emitLabel(ctx: var CGCtx, lbl: string) =
  ctx.outp.add lbl & ":\n"

proc err(ctx: var CGCtx, n: Node, msg: string) =
  let line = if n.isNil: 0 else: n.line
  let col = if n.isNil: 0 else: n.col
  ctx.diags.add errAt(ctx.file, line, col, msg, 1, "")
  ctx.hadError = true

proc widthSuffix(sz: int): string =
  case sz
  of 1: "b"
  of 2: "w"
  of 4: "l"
  else: "q"

proc sizeDirective(sz: int): string =
  case sz
  of 1: "byte"
  of 2: "word"
  of 4: "long"
  else: "quad"

const IntArgRegs64 = ["%rdi", "%rsi", "%rdx", "%rcx", "%r8", "%r9"]
const IntArgRegs32 = ["%edi", "%esi", "%edx", "%ecx", "%r8d", "%r9d"]
const IntArgRegs16 = ["%di", "%si", "%dx", "%cx", "%r8w", "%r9w"]
const IntArgRegs8 = ["%dil", "%sil", "%dl", "%cl", "%r8b", "%r9b"]

proc argRegFor(i, sz: int): string =
  case sz
  of 1: IntArgRegs8[i]
  of 2: IntArgRegs16[i]
  of 4: IntArgRegs32[i]
  else: IntArgRegs64[i]

# ============================== typy pomocnicze wyników ==============================

proc synthInt(): CType = ctype(tkInt)
proc synthULong(): CType = ctype(tkLong, true)

proc resultTypeOf(a, b: CType): CType =
  ## Bardzo uproszczone "zwyczajowe konwersje arytmetyczne" C - większy
  ## typ wygrywa (wg sizeof), przy remisie: unsigned wygrywa. Wystarcza
  ## dla typowego kodu całkowitoliczbowego; pełna zgodność ze standardem
  ## (promocje char/short->int, balansowanie signed/unsigned tej samej
  ## szerokości) - TODO, gdy pojawi się potrzeba większej precyzji.
  let sa = typeSizeOf(a)
  let sb = typeSizeOf(b)
  if sa > sb: a
  elif sb > sa: b
  elif isUnsignedType(a): a
  else: b

# ============================== dekodowanie literałów ==============================

## `raw` zawiera otaczające cudzysłowy i NIEZDEKODOWANE escape'y (tak
## zachowuje je lexer - patrz lexer.nim/lexString: kopiuje tekst źródłowy
## dosłownie). Zwraca zdekodowane bajty, BEZ końcowego NUL - dokleja go
## wołający tam, gdzie trzeba (pula rodata zawsze; inicjalizator tablicy
## znakowej też, ale przycięty do rozmiaru tablicy).
proc decodeCString(raw: string): string =
  result = ""
  if raw.len < 2: return
  var i = 1
  while i < raw.len - 1:
    if raw[i] == '\\' and i + 1 < raw.len - 1:
      inc i
      case raw[i]
      of 'n': result.add '\n'
      of 't': result.add '\t'
      of 'r': result.add '\r'
      of '0': result.add '\0'
      of 'a': result.add '\a'
      of 'b': result.add '\b'
      of 'f': result.add '\f'
      of 'v': result.add '\v'
      of '\\': result.add '\\'
      of '\'': result.add '\''
      of '"': result.add '"'
      else: result.add raw[i]  # nieznana sekwencja (np. \NNN ósemkowe) - TODO, na razie dosłownie
      inc i
    else:
      result.add raw[i]
      inc i

proc internString(ctx: var CGCtx, raw: string): string =
  let bytes = decodeCString(raw) & "\0"
  result = ".LCstr" & $ctx.strCounter
  inc ctx.strCounter
  ctx.rodataOut.add result & ":\n"
  var parts: seq[string] = @[]
  for ch in bytes: parts.add $ord(ch)
  ctx.rodataOut.add "    .byte " & parts.join(", ") & "\n"

## Typ literału int wg tekstu tokenu (sufiksy u/U/l/L/ll/LL) - bardzo
## uproszczone: nie modeluje pełnej reguły doboru "najmniejszy typ, który
## się mieści" ze standardu C, tylko honoruje jawne sufiksy.
proc internFloatConst(ctx: var CGCtx, bits: uint64): string =
  result = ".LCflt" & $ctx.strCounter
  inc ctx.strCounter
  ctx.rodataOut.add ".align 8\n" & result & ":\n    .quad 0x" & bits.toHex(16) & "\n"

## Parsuje tekst literału float/double (sufiksy f/F/l/L, notacja
## wykładnicza - lexer już je akceptuje, patrz lexNumber) na surowe bity
## IEEE754 double. Wewnętrznie WSZYSTKO trzymane jest jako double (patrz
## komentarz "float/double: uwaga o modelu" wyżej) - sufiks tylko
## decyduje o zwracanym `CType` (informacyjnie, do konwersji przy
## zapisie), nie o precyzji samej stałej.
proc parseFloatLiteralBits(text: string): uint64 =
  var s = text
  while s.len > 0 and s[^1] in {'f', 'F', 'l', 'L'}: s.setLen(s.len - 1)
  var v: float64
  try: v = parseFloat(s)
  except ValueError: v = 0.0
  result = cast[uint64](v)

proc literalIntType(text: string): CType =
  let low = text.toLowerAscii()
  let uns = 'u' in low
  let long = "ll" in low or (low.count('l') >= 1 and "ll" notin low and 'l' in low)
  if long: ctype(tkLong, uns) else: ctype(tkInt, uns)

# ============================== forward declarations ==============================

proc genExpr(ctx: var CGCtx, n: Node): CType
proc genAddr(ctx: var CGCtx, n: Node): CType
proc genStmt(ctx: var CGCtx, n: Node)
proc genLocalInit(ctx: var CGCtx, ty: CType, offset: int, init: Node)
proc typeOfExprNoEmit(ctx: var CGCtx, n: Node): CType
proc classifyArgTypes(types: seq[CType]): tuple[intReg, fltReg, stackPos: seq[int],
                                                  nInt, nFlt, nStack: int]

# ============================== symbol resolution ==============================

proc lookupSymbol(ctx: CGCtx, name: string): SymInfo =
  for i in countdown(ctx.scopes.len - 1, 0):
    if name in ctx.scopes[i]:
      let lv = ctx.scopes[i][name]
      return SymInfo(kind: siLocal, offset: lv.offset, typ: lv.typ)
  if name in ctx.enumConsts:
    return SymInfo(kind: siEnumConst, typ: synthInt())
  if name in ctx.globalVars:
    return SymInfo(kind: siGlobal, typ: ctx.globalVars[name])
  if name in ctx.funcSigs:
    return SymInfo(kind: siFunc, typ: ctx.funcSigs[name])
  SymInfo(kind: siUnknown, typ: tyErrorC())

proc pushScope(ctx: var CGCtx) = ctx.scopes.add initTable[string, LocalVar]()
proc popScope(ctx: var CGCtx) = discard ctx.scopes.pop()

proc declareLocal(ctx: var CGCtx, name: string, ty: CType): int =
  let sz = max(1, typeSizeOf(ty))
  let al = max(1, typeAlignOf(ty))
  ctx.frameUsed = ((ctx.frameUsed + al - 1) div al) * al
  ctx.frameUsed += sz
  result = -ctx.frameUsed
  if name.len > 0:
    ctx.scopes[^1][name] = (result, ty)

# ============================== float/double: uwaga o modelu ==============================
#
# Wewnętrznie WSZYSTKIE wartości zmiennoprzecinkowe liczone są jako double
# w %xmm0 (druga robocza wartość binarna: %xmm1) - `float` jest zawężane
# do/z double TYLKO na granicy pamięci (load/store) przez cvtss2sd/
# cvtsd2ss. Upraszcza to rdzeń arytmetyki (jeden zestaw instrukcji
# addsd/subsd/mulsd/divsd/ucomisd zamiast dwóch), kosztem odrobiny
# precyzji/wydajności dla czystych obliczeń na `float` - akceptowalny
# kompromis w MVP, udokumentowany w nagłówku modułu i w ROADMAP.md.
#
# Konwencja zwracana przez `genExpr`/`genAddr`+`genLoad`: wynik leży w
# %rax, jeśli zwrócony CType jest całkowity/wskaźnikowy, albo w %xmm0,
# jeśli jest zmiennoprzecinkowy - WOŁAJĄCY musi sprawdzić
# `isFloatingType` na zwróconym typie, żeby wiedzieć, gdzie szukać
# wartości. To samo dotyczy "wypychania" wartości na czas ewaluacji
# drugiego operandu: `pushXmm`/`popXmm` niżej, używane zamiast zwykłego
# `pushq %rax`/`popq` dokładnie tam, gdzie wartość jest zmiennoprzecinkowa.

proc pushXmm(ctx: var CGCtx, reg = "%xmm0") =
  ctx.emit("subq $8, %rsp")
  ctx.emit("movsd " & reg & ", (%rsp)")
  inc ctx.pushDepth

proc popXmm(ctx: var CGCtx, reg = "%xmm0") =
  ctx.emit("movsd (%rsp), " & reg)
  ctx.emit("addq $8, %rsp")
  dec ctx.pushDepth

## Zapewnia, że %rax zawiera wartość logiczną 0/1 odpowiadającą
## "prawdziwości" ostatnio obliczonej wartości typu `ty` (używane przez
## if/while/for/?:/&&/||/! - wszystkie one testują `%rax` przez `testq`
## niezależnie od tego, czy oryginalna wartość była całkowita, czy
## zmiennoprzecinkowa w %xmm0).
proc ensureRaxBool(ctx: var CGCtx, ty: CType) =
  if isFloatingType(ty):
    ctx.emit("pxor %xmm1, %xmm1")
    ctx.emit("ucomisd %xmm1, %xmm0")
    ctx.emit("setne %al")
    ctx.emit("movzbq %al, %rax")

# ============================== ładowanie/zapis pod adresem ==============================

proc loadFromMem(ctx: var CGCtx, t: CType, memOperand: string) =
  if isFloatingType(t):
    if t.kind == tkFloat:
      ctx.emit("movss " & memOperand & ", %xmm0")
      ctx.emit("cvtss2sd %xmm0, %xmm0")
    else:
      ctx.emit("movsd " & memOperand & ", %xmm0")
    return
  let sz = typeSizeOf(t)
  let uns = isUnsignedType(t)
  case sz
  of 1: ctx.emit((if uns: "movzbq " else: "movsbq ") & memOperand & ", %rax")
  of 2: ctx.emit((if uns: "movzwq " else: "movswq ") & memOperand & ", %rax")
  of 4:
    if uns: ctx.emit("movl " & memOperand & ", %eax")
    else: ctx.emit("movslq " & memOperand & ", %rax")
  else: ctx.emit("movq " & memOperand & ", %rax")

proc storeToMem(ctx: var CGCtx, t: CType, memOperand: string) =
  if isFloatingType(t):
    if t.kind == tkFloat:
      ctx.emit("cvtsd2ss %xmm0, %xmm0")
      ctx.emit("movss %xmm0, " & memOperand)
    else:
      ctx.emit("movsd %xmm0, " & memOperand)
    return
  let sz = typeSizeOf(t)
  case sz
  of 1: ctx.emit("movb %al, " & memOperand)
  of 2: ctx.emit("movw %ax, " & memOperand)
  of 4: ctx.emit("movl %eax, " & memOperand)
  else: ctx.emit("movq %rax, " & memOperand)

proc adjustWidth(ctx: var CGCtx, t: CType) =
  ## Dopasowuje bieżącą wartość w %rax (traktowaną jako pełne 64 bity)
  ## do szerokości/znaku docelowego typu skalarnego - używane przy cast
  ## MIĘDZY typami całkowitymi/wskaźnikowymi. Konwersje z/do float/double
  ## są osobno w `genCast` (tam też %rax vs %xmm0 wymaga innej logiki niż
  ## samo "dopasowanie szerokości").
  if isPointerLikeType(t): return
  let sz = typeSizeOf(t)
  let uns = isUnsignedType(t)
  case sz
  of 1: ctx.emit((if uns: "movzbq %al, %rax" else: "movsbq %al, %rax"))
  of 2: ctx.emit((if uns: "movzwq %ax, %rax" else: "movswq %ax, %rax"))
  of 4:
    if uns: ctx.emit("movl %eax, %eax")
    else: ctx.emit("movslq %eax, %rax")
  else: discard

proc zeroMem(ctx: var CGCtx, offset, size: int) =
  var i = 0
  while i < size:
    if size - i >= 8: ctx.emit("movq $0, " & $(offset + i) & "(%rbp)"); i += 8
    elif size - i >= 4: ctx.emit("movl $0, " & $(offset + i) & "(%rbp)"); i += 4
    elif size - i >= 2: ctx.emit("movw $0, " & $(offset + i) & "(%rbp)"); i += 2
    else: ctx.emit("movb $0, " & $(offset + i) & "(%rbp)"); i += 1

# ============================== genAddr / genLoad ==============================

proc genAddr(ctx: var CGCtx, n: Node): CType =
  if n.isNil:
    ctx.err(n, "wewnętrzny błąd codegenu: pusty węzeł l-wartości")
    return tyErrorC()
  case n.kind
  of nkIdent:
    let info = ctx.lookupSymbol(n.strVal)
    case info.kind
    of siLocal:
      ctx.emit("leaq " & $info.offset & "(%rbp), %rax")
      return info.typ
    of siGlobal:
      ctx.emit("leaq " & n.strVal & "(%rip), %rax")
      return info.typ
    of siFunc:
      ctx.emit("leaq " & n.strVal & "(%rip), %rax")
      return info.typ
    of siEnumConst:
      ctx.err(n, "'" & n.strVal & "' jest stałą wyliczeniową, nie l-wartością")
      return tyErrorC()
    of siUnknown:
      ctx.err(n, "nieznany identyfikator '" & n.strVal & "'")
      return tyErrorC()
  of nkIndex:
    let tA = genExpr(ctx, n.a)
    ctx.emit("pushq %rax"); inc ctx.pushDepth
    discard genExpr(ctx, n.b)
    ctx.emit("movq %rax, %rcx")
    ctx.emit("popq %rax"); dec ctx.pushDepth
    let elemTy = pointeeOf(tA)
    if elemTy.isNil:
      ctx.err(n, "indeksowanie wartości, która nie jest wskaźnikiem ani tablicą")
      return tyErrorC()
    let elemSz = typeSizeOf(elemTy)
    if elemSz != 1:
      ctx.emit("imulq $" & $elemSz & ", %rcx")
    ctx.emit("addq %rcx, %rax")
    return elemTy
  of nkMember:
    let baseTy = genAddr(ctx, n.a)
    let off = fieldOffset(baseTy, n.strVal)
    if off < 0:
      ctx.err(n, "typ '" & typeToString(baseTy) & "' nie ma pola '" & n.strVal & "'")
      return tyErrorC()
    if off != 0: ctx.emit("addq $" & $off & ", %rax")
    return fieldType(baseTy, n.strVal)
  of nkArrow:
    let ptrTy = genExpr(ctx, n.a)
    let baseTy = pointeeOf(ptrTy)
    if baseTy.isNil:
      ctx.err(n, "'->' użyte na wartości, która nie jest wskaźnikiem")
      return tyErrorC()
    let off = fieldOffset(baseTy, n.strVal)
    if off < 0:
      ctx.err(n, "typ '" & typeToString(baseTy) & "' nie ma pola '" & n.strVal & "'")
      return tyErrorC()
    if off != 0: ctx.emit("addq $" & $off & ", %rax")
    return fieldType(baseTy, n.strVal)
  of nkUnaryPre:
    if n.op == "*":
      let ptrTy = genExpr(ctx, n.a)
      let baseTy = pointeeOf(ptrTy)
      if baseTy.isNil:
        ctx.err(n, "'*' użyte na wartości, która nie jest wskaźnikiem")
        return tyErrorC()
      return baseTy
    ctx.err(n, "wyrażenie nie jest l-wartością")
    return tyErrorC()
  else:
    ctx.err(n, "wyrażenie nie jest l-wartością")
    return tyErrorC()

proc genLoad(ctx: var CGCtx, n: Node): CType =
  result = genAddr(ctx, n)
  if isScalarType(result):
    loadFromMem(ctx, result, "(%rax)")

# ============================== wyrażenia: pomocnicze operatory ==============================

proc genIncDecPre(ctx: var CGCtx, n: Node): CType =
  result = genAddr(ctx, n.a)
  ctx.emit("pushq %rax"); inc ctx.pushDepth
  loadFromMem(ctx, result, "(%rax)")
  if isFloatingType(result):
    let one = ctx.internFloatConst(cast[uint64](1.0'f64))
    ctx.emit("movsd " & one & "(%rip), %xmm1")
    if n.op == "++": ctx.emit("addsd %xmm1, %xmm0") else: ctx.emit("subsd %xmm1, %xmm0")
  else:
    let step = if isPointerLikeType(result): typeSizeOf(pointeeOf(result)) else: 1
    if n.op == "++": ctx.emit("addq $" & $step & ", %rax")
    else: ctx.emit("subq $" & $step & ", %rax")
  ctx.emit("popq %rcx"); dec ctx.pushDepth
  storeToMem(ctx, result, "(%rcx)")

proc genIncDecPost(ctx: var CGCtx, n: Node): CType =
  result = genAddr(ctx, n.a)
  ctx.emit("pushq %rax"); inc ctx.pushDepth
  loadFromMem(ctx, result, "(%rax)")
  if isFloatingType(result):
    ctx.emit("movsd %xmm0, %xmm2")  # %xmm2 = stara wartość (do zwrócenia na końcu)
    let one = ctx.internFloatConst(cast[uint64](1.0'f64))
    ctx.emit("movsd " & one & "(%rip), %xmm1")
    if n.op == "++": ctx.emit("addsd %xmm1, %xmm0") else: ctx.emit("subsd %xmm1, %xmm0")
    ctx.emit("popq %rcx"); dec ctx.pushDepth
    storeToMem(ctx, result, "(%rcx)")
    ctx.emit("movsd %xmm2, %xmm0")
  else:
    ctx.emit("movq %rax, %rdx")
    let step = if isPointerLikeType(result): typeSizeOf(pointeeOf(result)) else: 1
    if n.op == "++": ctx.emit("addq $" & $step & ", %rax")
    else: ctx.emit("subq $" & $step & ", %rax")
    ctx.emit("popq %rcx"); dec ctx.pushDepth
    storeToMem(ctx, result, "(%rcx)")
    ctx.emit("movq %rdx, %rax")

proc genBinary(ctx: var CGCtx, n: Node): CType =
  if n.op == "&&":
    let lbl0 = ctx.newLabel()
    let lblEnd = ctx.newLabel()
    ensureRaxBool(ctx, genExpr(ctx, n.a))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jz " & lbl0)
    ensureRaxBool(ctx, genExpr(ctx, n.b))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jz " & lbl0)
    ctx.emit("movq $1, %rax")
    ctx.emit("jmp " & lblEnd)
    ctx.emitLabel(lbl0)
    ctx.emit("movq $0, %rax")
    ctx.emitLabel(lblEnd)
    return synthInt()
  if n.op == "||":
    let lbl1 = ctx.newLabel()
    let lblEnd = ctx.newLabel()
    ensureRaxBool(ctx, genExpr(ctx, n.a))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jnz " & lbl1)
    ensureRaxBool(ctx, genExpr(ctx, n.b))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jnz " & lbl1)
    ctx.emit("movq $0, %rax")
    ctx.emit("jmp " & lblEnd)
    ctx.emitLabel(lbl1)
    ctx.emit("movq $1, %rax")
    ctx.emitLabel(lblEnd)
    return synthInt()

  let tA = genExpr(ctx, n.a)
  if isFloatingType(tA): pushXmm(ctx)
  else: ctx.emit("pushq %rax"); inc ctx.pushDepth
  let tB = genExpr(ctx, n.b)
  let floatOp = isFloatingType(tA) or isFloatingType(tB)

  if floatOp:
    if n.op in ["&", "|", "^", "<<", ">>", "%"]:
      ctx.err(n, "operator '" & n.op & "' niedozwolony dla typów zmiennoprzecinkowych")
      if isFloatingType(tA): popXmm(ctx) else: (ctx.emit("popq %rax"); dec ctx.pushDepth)
      return synthInt()
    # %xmm1 = prawy operand (jako double)
    if isFloatingType(tB): ctx.emit("movsd %xmm0, %xmm1")
    else: ctx.emit("cvtsi2sd %rax, %xmm1")
    # %xmm0 = lewy operand (jako double), odtworzony ze stosu
    if isFloatingType(tA):
      popXmm(ctx, "%xmm0")
    else:
      ctx.emit("popq %rax"); dec ctx.pushDepth
      ctx.emit("cvtsi2sd %rax, %xmm0")
    case n.op
    of "+": ctx.emit("addsd %xmm1, %xmm0"); return ctype(tkDouble)
    of "-": ctx.emit("subsd %xmm1, %xmm0"); return ctype(tkDouble)
    of "*": ctx.emit("mulsd %xmm1, %xmm0"); return ctype(tkDouble)
    of "/": ctx.emit("divsd %xmm1, %xmm0"); return ctype(tkDouble)
    of "==", "!=", "<", ">", "<=", ">=":
      ctx.emit("ucomisd %xmm1, %xmm0")
      let setcc = case n.op
        of "==": "sete"
        of "!=": "setne"
        of "<": "setb"
        of ">": "seta"
        of "<=": "setbe"
        else: "setae"
      ctx.emit(setcc & " %al")
      ctx.emit("movzbq %al, %rax")
      return synthInt()
    else:
      ctx.err(n, "nieobsługiwany operator zmiennoprzecinkowy '" & n.op & "'")
      return synthInt()

  # --- ścieżka całkowitoliczbowa/wskaźnikowa (bez zmian) ---
  ctx.emit("movq %rax, %rcx")
  ctx.emit("popq %rax"); dec ctx.pushDepth
  # od tego miejsca: %rax = lewy operand, %rcx = prawy operand

  if n.op in ["+", "-"]:
    let aPtr = isPointerLikeType(tA)
    let bPtr = isPointerLikeType(tB)
    if aPtr and bPtr and n.op == "-":
      let elemSz = typeSizeOf(pointeeOf(tA))
      ctx.emit("subq %rcx, %rax")
      if elemSz > 1:
        ctx.emit("movq $" & $elemSz & ", %rcx")
        ctx.emit("cqto")
        ctx.emit("idivq %rcx")
      return ctype(tkLong)
    elif aPtr and not bPtr:
      let elemSz = typeSizeOf(pointeeOf(tA))
      if elemSz > 1: ctx.emit("imulq $" & $elemSz & ", %rcx")
      ctx.emit((if n.op == "+": "addq %rcx, %rax" else: "subq %rcx, %rax"))
      return tA
    elif bPtr and not aPtr and n.op == "+":
      let elemSz = typeSizeOf(pointeeOf(tB))
      if elemSz > 1: ctx.emit("imulq $" & $elemSz & ", %rax")
      ctx.emit("addq %rcx, %rax")
      return tB
    else:
      ctx.emit((if n.op == "+": "addq %rcx, %rax" else: "subq %rcx, %rax"))
      return resultTypeOf(tA, tB)
  elif n.op == "*":
    ctx.emit("imulq %rcx, %rax")
    return resultTypeOf(tA, tB)
  elif n.op == "/":
    let uns = isUnsignedType(tA) or isUnsignedType(tB)
    if uns: ctx.emit("xorq %rdx, %rdx"); ctx.emit("divq %rcx")
    else: ctx.emit("cqto"); ctx.emit("idivq %rcx")
    return resultTypeOf(tA, tB)
  elif n.op == "%":
    let uns = isUnsignedType(tA) or isUnsignedType(tB)
    if uns: ctx.emit("xorq %rdx, %rdx"); ctx.emit("divq %rcx")
    else: ctx.emit("cqto"); ctx.emit("idivq %rcx")
    ctx.emit("movq %rdx, %rax")
    return resultTypeOf(tA, tB)
  elif n.op == "<<":
    ctx.emit("salq %cl, %rax")
    return tA
  elif n.op == ">>":
    if isUnsignedType(tA): ctx.emit("shrq %cl, %rax")
    else: ctx.emit("sarq %cl, %rax")
    return tA
  elif n.op in ["&", "|", "^"]:
    case n.op
    of "&": ctx.emit("andq %rcx, %rax")
    of "|": ctx.emit("orq %rcx, %rax")
    else: ctx.emit("xorq %rcx, %rax")
    return resultTypeOf(tA, tB)
  elif n.op in ["==", "!=", "<", ">", "<=", ">="]:
    ctx.emit("cmpq %rcx, %rax")
    let uns = isUnsignedType(tA) or isUnsignedType(tB) or isPointerLikeType(tA)
    let setcc = case n.op
      of "==": "sete"
      of "!=": "setne"
      of "<": (if uns: "setb" else: "setl")
      of ">": (if uns: "seta" else: "setg")
      of "<=": (if uns: "setbe" else: "setle")
      else: (if uns: "setae" else: "setge")
    ctx.emit(setcc & " %al")
    ctx.emit("movzbq %al, %rax")
    return synthInt()
  else:
    ctx.err(n, "nieobsługiwany operator binarny '" & n.op & "'")
    return synthInt()

proc genAssign(ctx: var CGCtx, n: Node): CType =
  if n.op == "=":
    let lhsTy = genAddr(ctx, n.a)
    if lhsTy.kind in {tkStruct, tkUnion}:
      ctx.emit("pushq %rax"); inc ctx.pushDepth
      discard genAddr(ctx, n.b)
      ctx.emit("movq %rax, %rsi")
      ctx.emit("popq %rdi"); dec ctx.pushDepth
      ctx.emit("movq $" & $typeSizeOf(lhsTy) & ", %rcx")
      ctx.emit("rep movsb")
      ctx.emit("movq %rdi, %rax")
      return lhsTy
    else:
      ctx.emit("pushq %rax"); inc ctx.pushDepth
      let rhsTy = genExpr(ctx, n.b)
      # niejawna konwersja int<->float na granicy przypisania (np. `float
      # x = 1;` albo `int y = 3.9;`) - `storeToMem` poniżej i tak oczekuje
      # wartości w rejestrze zgodnym z `lhsTy`, więc trzeba ją tu dociągnąć
      if isFloatingType(lhsTy) and not isFloatingType(rhsTy):
        ctx.emit("cvtsi2sd %rax, %xmm0")
      elif not isFloatingType(lhsTy) and isFloatingType(rhsTy):
        ctx.emit("cvttsd2si %xmm0, %rax")
        if isScalarType(lhsTy): adjustWidth(ctx, lhsTy)
      ctx.emit("popq %rcx"); dec ctx.pushDepth
      storeToMem(ctx, lhsTy, "(%rcx)")
      return lhsTy
  else:
    let lhsTy = genAddr(ctx, n.a)
    ctx.emit("pushq %rax"); inc ctx.pushDepth
    let rhsTy = genExpr(ctx, n.b)
    let baseOp = n.op[0 ..< n.op.len - 1]
    if isFloatingType(lhsTy):
      if not isFloatingType(rhsTy): ctx.emit("cvtsi2sd %rax, %xmm0")
      ctx.emit("movsd %xmm0, %xmm1")          # %xmm1 = prawa strona (double)
      ctx.emit("popq %r8"); dec ctx.pushDepth   # %r8 = adres lewej strony
      loadFromMem(ctx, lhsTy, "(%r8)")           # %xmm0 = bieżąca wartość (double)
      case baseOp
      of "+": ctx.emit("addsd %xmm1, %xmm0")
      of "-": ctx.emit("subsd %xmm1, %xmm0")
      of "*": ctx.emit("mulsd %xmm1, %xmm0")
      of "/": ctx.emit("divsd %xmm1, %xmm0")
      else: ctx.err(n, "operator przypisania złożonego '" & n.op &
        "' niedozwolony dla typów zmiennoprzecinkowych")
      storeToMem(ctx, lhsTy, "(%r8)")
      return lhsTy
    else:
      if isFloatingType(rhsTy): ctx.emit("cvttsd2si %xmm0, %rax")
      ctx.emit("pushq %rax"); inc ctx.pushDepth
      ctx.emit("movq (%rsp), %rcx")     # rcx = prawa strona
      ctx.emit("movq 8(%rsp), %r8")     # r8  = adres lewej strony (BEZPIECZNY - poza rax/rcx/rdx używanymi przez idiv)
      loadFromMem(ctx, lhsTy, "(%r8)")  # %rax = bieżąca wartość
      case baseOp
      of "+":
        if isPointerLikeType(lhsTy):
          let elemSz = typeSizeOf(pointeeOf(lhsTy))
          if elemSz > 1: ctx.emit("imulq $" & $elemSz & ", %rcx")
        ctx.emit("addq %rcx, %rax")
      of "-":
        if isPointerLikeType(lhsTy):
          let elemSz = typeSizeOf(pointeeOf(lhsTy))
          if elemSz > 1: ctx.emit("imulq $" & $elemSz & ", %rcx")
        ctx.emit("subq %rcx, %rax")
      of "*": ctx.emit("imulq %rcx, %rax")
      of "/":
        if isUnsignedType(lhsTy): ctx.emit("xorq %rdx, %rdx"); ctx.emit("divq %rcx")
        else: ctx.emit("cqto"); ctx.emit("idivq %rcx")
      of "%":
        if isUnsignedType(lhsTy): ctx.emit("xorq %rdx, %rdx"); ctx.emit("divq %rcx")
        else: ctx.emit("cqto"); ctx.emit("idivq %rcx")
        ctx.emit("movq %rdx, %rax")
      of "<<": ctx.emit("salq %cl, %rax")
      of ">>":
        if isUnsignedType(lhsTy): ctx.emit("shrq %cl, %rax") else: ctx.emit("sarq %cl, %rax")
      of "&": ctx.emit("andq %rcx, %rax")
      of "|": ctx.emit("orq %rcx, %rax")
      of "^": ctx.emit("xorq %rcx, %rax")
      else: ctx.err(n, "nieobsługiwany operator przypisania złożonego '" & n.op & "'")
      storeToMem(ctx, lhsTy, "(%r8)")
      ctx.emit("addq $16, %rsp"); ctx.pushDepth -= 2
      return lhsTy

proc genCond(ctx: var CGCtx, n: Node): CType =
  let lElse = ctx.newLabel()
  let lEnd = ctx.newLabel()
  let condTy = genExpr(ctx, n.a)
  ensureRaxBool(ctx, condTy)
  ctx.emit("testq %rax, %rax")
  ctx.emit("jz " & lElse)
  # Podgląd typów OBU gałęzi z wyprzedzeniem (bez emisji - `typeOfExprNoEmit`),
  # żeby wiedzieć, czy wynik całego ?: ma być zmiennoprzecinkowy - C
  # balansuje typy między gałęziami (int : double -> double), a obie
  # gałęzie muszą się zgodzić co do tego, w którym rejestrze (%rax czy
  # %xmm0) zostawiają wynik, mimo że generujemy je do dwóch różnych,
  # rozłącznych ścieżek kodu (then/else) - stąd decyzja PRZED wygenerowaniem.
  let resultFloat = isFloatingType(typeOfExprNoEmit(ctx, n.b)) or
                     isFloatingType(typeOfExprNoEmit(ctx, n.c))
  let tThen = genExpr(ctx, n.b)
  if resultFloat and not isFloatingType(tThen): ctx.emit("cvtsi2sd %rax, %xmm0")
  ctx.emit("jmp " & lEnd)
  ctx.emitLabel(lElse)
  let tElse = genExpr(ctx, n.c)
  if resultFloat and not isFloatingType(tElse): ctx.emit("cvtsi2sd %rax, %xmm0")
  ctx.emitLabel(lEnd)
  result = if resultFloat: ctype(tkDouble)
           elif isScalarType(tThen): tThen else: tElse

proc genCast(ctx: var CGCtx, n: Node): CType =
  let srcTy = genExpr(ctx, n.a)
  let srcFloat = isFloatingType(srcTy)
  let dstFloat = isFloatingType(n.typ)
  if srcFloat and dstFloat:
    discard  # już double w %xmm0 wewnętrznie; ewentualne zawężenie do float robi storeToMem przy zapisie
  elif srcFloat and not dstFloat:
    ctx.emit("cvttsd2si %xmm0, %rax")  # obcięcie w stronę zera, jak w C
    if isScalarType(n.typ): adjustWidth(ctx, n.typ)
  elif dstFloat and not srcFloat:
    # UWAGA: cvtsi2sd zakłada %rax jako signed 64-bit - dla unsigned o
    # wartości > 2^63 dałoby błędny wynik (rzadki przypadek, TODO)
    ctx.emit("cvtsi2sd %rax, %xmm0")
  elif isScalarType(n.typ):
    adjustWidth(ctx, n.typ)
  result = n.typ

proc resolveFnType(t: CType): CType =
  if t.isNil: return nil
  if t.kind == tkFunction: return t
  if t.kind == tkPointer and not t.pointee.isNil and t.pointee.kind == tkFunction: return t.pointee
  nil

proc genArgsCommon(ctx: var CGCtx, args: seq[Node]): int =
  ## Ewaluuje argumenty (kolejność: prawo-do-lewa, standardowa dla tego
  ## codegenu), wypycha WSZYSTKIE (int przez `pushq`, float przez
  ## `pushXmm`) na tymczasowy, ciasny obszar na stosie, po czym:
  ## 1. czyta argumenty rejestrowe (wg `classifyArgTypes`, symetrycznej
  ##    z tym, czego oczekuje `genFunction` po stronie wywoływanej) przez
  ##    zwykłe odczyty spod stałych offsetów (BEZ zdejmowania ze stosu -
  ##    stos wciąż zawiera WSZYSTKIE N argumentów w tym momencie);
  ## 2. dla argumentów, które nie zmieściły się w żadnej klasie
  ##    rejestrów, rezerwuje nowy, ciasny region i PRZEPISUJE je tam we
  ##    właściwej, lewo-prawo kolejności.
  ## Ten dwuetapowy schemat (czytaj-przez-offset, potem kompaktuj) jest
  ## konieczny, bo argumenty int i float mają NIEZALEŻNE liczniki
  ## rejestrów - argument stosowy i argument rejestrowy mogą się
  ## przeplatać w dowolnej kolejności (np. 7 argumentów int + 1 float:
  ## siódmy int ląduje na stosie, ale float PO NIM wciąż mieści się w
  ## %xmm0) - zwykłe sekwencyjne `pop` by tego nie obsłużyło poprawnie,
  ## bo pierwszy "zostawiony" na stosie argument blokowałby dostęp do
  ## tego, co jest pod nim.
  ## Zwraca liczbę bajtów do posprzątania PO `call`, NIE licząc niczego
  ## odłożonego przez wołającego PRZED tym wywołaniem (np. adres funkcji
  ## przy wywołaniu pośrednim - patrz `genCall`).
  let nArgs = args.len
  var argTypes = newSeq[CType](nArgs)
  for i in 0 ..< nArgs:
    argTypes[i] = typeOfExprNoEmit(ctx, args[i])
  let cls = classifyArgTypes(argTypes)

  let needsPad = (ctx.pushDepth + nArgs + cls.nStack) mod 2 != 0
  if needsPad:
    ctx.emit("subq $8, %rsp"); inc ctx.pushDepth

  for i in countdown(nArgs - 1, 0):
    let ty = genExpr(ctx, args[i])
    if isFloatingType(ty): pushXmm(ctx)
    else: (ctx.emit("pushq %rax"); inc ctx.pushDepth)

  for i in 0 ..< nArgs:
    if cls.intReg[i] >= 0:
      ctx.emit("movq " & $(8 * i) & "(%rsp), " & IntArgRegs64[cls.intReg[i]])
    elif cls.fltReg[i] >= 0:
      ctx.emit("movsd " & $(8 * i) & "(%rsp), %xmm" & $cls.fltReg[i])

  if cls.nStack > 0:
    ctx.emit("subq $" & $(8 * cls.nStack) & ", %rsp")
    inc ctx.pushDepth, cls.nStack
    for i in 0 ..< nArgs:
      if cls.stackPos[i] >= 0:
        ctx.emit("movq " & $(8 * cls.nStack + 8 * i) & "(%rsp), %r11")
        ctx.emit("movq %r11, " & $(8 * cls.stackPos[i]) & "(%rsp)")

  ctx.emit("movb $" & $cls.nFlt & ", %al")  # SysV: liczba użytych rejestrów XMM (dla wariadycznych)
  result = 8 * nArgs + 8 * cls.nStack + (if needsPad: 8 else: 0)

proc genCall(ctx: var CGCtx, n: Node): CType =
  if n.a.kind == nkIdent and n.a.strVal in ctx.funcSigs:
    let fty = ctx.funcSigs[n.a.strVal]
    let cleanup = genArgsCommon(ctx, n.list)
    ctx.emit("call " & n.a.strVal)
    if cleanup > 0:
      ctx.emit("addq $" & $cleanup & ", %rsp")
      ctx.pushDepth -= cleanup div 8
    result = if fty.returnType.isNil: tyVoidC() else: fty.returnType
  else:
    let calleeTy = genExpr(ctx, n.a)
    let fnTy = resolveFnType(calleeTy)
    if fnTy.isNil:
      ctx.err(n, "wywołanie wartości, która nie jest funkcją ani wskaźnikiem do funkcji")
      ctx.emit("movq $0, %rax")
      return synthInt()
    ctx.emit("pushq %rax"); inc ctx.pushDepth
    let cleanup = genArgsCommon(ctx, n.list)
    ctx.emit("movq " & $cleanup & "(%rsp), %r10")
    ctx.emit("call *%r10")
    let total = cleanup + 8
    ctx.emit("addq $" & $total & ", %rsp")
    ctx.pushDepth -= total div 8
    result = if fnTy.returnType.isNil: tyVoidC() else: fnTy.returnType

## `sizeof(wyrażenie)` w C NIE ewaluuje wyrażenia (poza VLA, nieobsługiwanymi
## tutaj) - potrzebujemy jego typu bez skutków ubocznych w wynikowym kodzie.
## Sztuczka: generujemy normalnie do bufora-śmietnika i odrzucamy tekst -
## bezpieczne, bo i tak nic z tego nie trafia do finalnego pliku wynikowego
## (żadna prawdziwa "ewaluacja" się nie dzieje, to tylko generowanie tekstu).
## Używane też do "podglądu" typu argumentu przed jego właściwą generacją
## (np. klasyfikacja rejestrów w `genArgsCommon`) - w TYCH miejscach
## wyrażenie faktycznie generuje się DWA razy (raz na śmietnik, raz na
## serio). Nieszkodliwe dla poprawności (drugi, prawdziwy przebieg i tak
## nadpisuje/używa świeżo obliczonych wartości), ale ma efekt uboczny:
## literały string/float w takim wyrażeniu trafiają do `.rodata` DWA
## razy (jeden wpis zostaje osierocony, nieużywany) - `ctx.rodataOut`/
## `strCounter` NIE są izolowane tym samym mechanizmem co `ctx.outp`.
## Kosmetyczna strata miejsca w pliku wynikowym, nie błąd poprawności -
## TODO, jeśli kiedyś będzie to problemem (np. bardzo duże pule stałych).
proc typeOfExprNoEmit(ctx: var CGCtx, n: Node): CType =
  let saved = ctx.outp
  ctx.outp = ""
  result = genExpr(ctx, n)
  ctx.outp = saved

proc genExpr(ctx: var CGCtx, n: Node): CType =
  if n.isNil:
    ctx.err(n, "wewnętrzny błąd codegenu: pusty węzeł wyrażenia")
    return synthInt()
  case n.kind
  of nkIntLit:
    let (ok, v) = evalConstInt(n)
    if not ok:
      ctx.err(n, "nie można obliczyć literału całkowitego '" & n.strVal & "'")
      ctx.emit("movq $0, %rax")
      return synthInt()
    ctx.emit("movq $" & $v & ", %rax")
    return literalIntType(n.strVal)
  of nkCharLit:
    let (ok, v) = evalConstInt(n)
    ctx.emit("movq $" & $(if ok: v else: 0'i64) & ", %rax")
    return synthInt()
  of nkFloatLit:
    let bits = parseFloatLiteralBits(n.strVal)
    let lbl = ctx.internFloatConst(bits)
    ctx.emit("movsd " & lbl & "(%rip), %xmm0")
    let low = n.strVal.toLowerAscii()
    return (if 'f' in low: ctype(tkFloat) else: ctype(tkDouble))
  of nkStringLit:
    let lbl = ctx.internString(n.strVal)
    ctx.emit("leaq " & lbl & "(%rip), %rax")
    return pointerTo(ctype(tkChar))
  of nkIdent, nkIndex, nkMember, nkArrow:
    return genLoad(ctx, n)
  of nkUnaryPre:
    case n.op
    of "*": return genLoad(ctx, n)
    of "&": return pointerTo(genAddr(ctx, n.a))
    of "++", "--": return genIncDecPre(ctx, n)
    of "-":
      let t = genExpr(ctx, n.a)
      if isFloatingType(t):
        ctx.emit("pxor %xmm1, %xmm1")
        ctx.emit("subsd %xmm0, %xmm1")
        ctx.emit("movsd %xmm1, %xmm0")
      else:
        ctx.emit("negq %rax")
      return t
    of "+":
      return genExpr(ctx, n.a)
    of "~":
      let t = genExpr(ctx, n.a)
      if isFloatingType(t):
        ctx.err(n, "operator '~' niedozwolony dla typów zmiennoprzecinkowych")
      else:
        ctx.emit("notq %rax")
      return t
    of "!":
      let t = genExpr(ctx, n.a)
      ensureRaxBool(ctx, t)
      ctx.emit("testq %rax, %rax")
      ctx.emit("sete %al")
      ctx.emit("movzbq %al, %rax")
      return synthInt()
    else:
      ctx.err(n, "nieobsługiwany operator jednoargumentowy '" & n.op & "'")
      ctx.emit("movq $0, %rax")
      return synthInt()
  of nkUnaryPost:
    return genIncDecPost(ctx, n)
  of nkBinary:
    return genBinary(ctx, n)
  of nkAssign:
    return genAssign(ctx, n)
  of nkCond:
    return genCond(ctx, n)
  of nkCall:
    return genCall(ctx, n)
  of nkCast:
    return genCast(ctx, n)
  of nkSizeofType:
    ctx.emit("movq $" & $typeSizeOf(n.typ) & ", %rax")
    return synthULong()
  of nkSizeofExpr:
    let ty = typeOfExprNoEmit(ctx, n.a)
    ctx.emit("movq $" & $typeSizeOf(ty) & ", %rax")
    return synthULong()
  of nkComma:
    result = tyVoidC()
    for e in n.list:
      result = genExpr(ctx, e)
  of nkInitList:
    ctx.err(n, "lista inicjalizująca użyta jako zwykłe wyrażenie - nieobsługiwane")
    ctx.emit("movq $0, %rax")
    return synthInt()
  else:
    ctx.err(n, "nieobsługiwany rodzaj wyrażenia w codegenie: " & $n.kind)
    ctx.emit("movq $0, %rax")
    return synthInt()

# ============================== inicjalizatory lokalne ==============================

proc genLocalInit(ctx: var CGCtx, ty: CType, offset: int, init: Node) =
  if init.isNil: return
  if isScalarType(ty):
    var actual = init
    if init.kind == nkInitList:
      if init.list.len == 0: return
      if init.list.len > 1:
        ctx.err(init, "za dużo elementów w inicjalizatorze wartości skalarnej")
      actual = init.list[0]
    let initTy = genExpr(ctx, actual)
    if isFloatingType(ty) and not isFloatingType(initTy):
      ctx.emit("cvtsi2sd %rax, %xmm0")
    elif not isFloatingType(ty) and isFloatingType(initTy):
      ctx.emit("cvttsd2si %xmm0, %rax")
      if isScalarType(ty): adjustWidth(ctx, ty)
    storeToMem(ctx, ty, $offset & "(%rbp)")
  elif ty.kind == tkArray:
    let elemTy = ty.elem
    let elemSz = typeSizeOf(elemTy)
    let n = arrayLenOf(ty)
    if n < 0:
      ctx.err(init, "rozmiar tablicy nie jest stałą znaną w czasie kompilacji (VLA nieobsługiwane)")
      return
    if init.kind == nkStringLit and not elemTy.isNil and elemTy.kind == tkChar:
      let bytes = decodeCString(init.strVal) & "\0"
      for i in 0 ..< n:
        let b = if i < bytes.len: ord(bytes[i]) else: 0
        ctx.emit("movb $" & $b & ", " & $(offset + i) & "(%rbp)")
    elif init.kind == nkInitList:
      for i in 0 ..< n:
        let elemOff = offset + i * elemSz
        if i < init.list.len:
          genLocalInit(ctx, elemTy, elemOff, init.list[i])
        else:
          zeroMem(ctx, elemOff, elemSz)
    else:
      ctx.err(init, "nieobsługiwany inicjalizator tablicy")
  elif ty.kind in {tkStruct, tkUnion}:
    if init.kind != nkInitList:
      ctx.err(init, "nieobsługiwany inicjalizator struct/union")
      return
    for i, f in resolvedFields(ty):
      let foff = offset + fieldOffset(ty, f.name)
      if ty.kind == tkUnion and i > 0: break  # union: tylko pierwsze pole z inicjalizatora pozycyjnego
      if i < init.list.len:
        genLocalInit(ctx, f.typ, foff, init.list[i])
      elif ty.kind == tkStruct:
        zeroMem(ctx, foff, typeSizeOf(f.typ))
  else:
    ctx.err(init, "nieobsługiwany typ inicjalizowanej zmiennej: " & typeToString(ty))

# ============================== switch ==============================

proc collectCaseLabels(ctx: var CGCtx, n: Node,
                        into: var seq[tuple[isDefault: bool, val: int64, lbl: string]]) =
  if n.isNil: return
  case n.kind
  of nkSwitchStmt: return  # zagnieżdżony switch ma własny, osobny zestaw etykiet
  of nkCaseStmt:
    let (ok, v) = evalConstInt(n.a)
    if not ok: ctx.err(n, "etykieta 'case' musi być stałą całkowitą")
    let lbl = ctx.newLabel()
    ctx.caseLabels[cast[pointer](n)] = lbl
    into.add (false, v, lbl)
    collectCaseLabels(ctx, n.b, into)
  of nkDefaultStmt:
    let lbl = ctx.newLabel()
    ctx.caseLabels[cast[pointer](n)] = lbl
    into.add (true, 0'i64, lbl)
    collectCaseLabels(ctx, n.a, into)
  else:
    for c in [n.a, n.b, n.c, n.d]: collectCaseLabels(ctx, c, into)
    for c in n.list: collectCaseLabels(ctx, c, into)

proc genSwitch(ctx: var CGCtx, n: Node) =
  let lEnd = ctx.newLabel()
  var cases: seq[tuple[isDefault: bool, val: int64, lbl: string]] = @[]
  collectCaseLabels(ctx, n.b, cases)
  discard genExpr(ctx, n.a)
  let slotOff = declareLocal(ctx, "", ctype(tkLong))
  ctx.emit("movq %rax, " & $slotOff & "(%rbp)")
  var defaultLbl = ""
  for c in cases:
    if c.isDefault:
      defaultLbl = c.lbl
      continue
    ctx.emit("movq " & $slotOff & "(%rbp), %rax")
    ctx.emit("cmpq $" & $c.val & ", %rax")
    ctx.emit("je " & c.lbl)
  if defaultLbl.len > 0: ctx.emit("jmp " & defaultLbl)
  else: ctx.emit("jmp " & lEnd)
  ctx.breakLabels.add lEnd
  genStmt(ctx, n.b)
  discard ctx.breakLabels.pop()
  ctx.emitLabel(lEnd)

# ============================== instrukcje ==============================

proc genStmt(ctx: var CGCtx, n: Node) =
  if n.isNil: return
  case n.kind
  of nkCompound:
    pushScope(ctx)
    for s in n.list: genStmt(ctx, s)
    popScope(ctx)
  of nkExprStmt:
    if not n.a.isNil: discard genExpr(ctx, n.a)
  of nkIf:
    ensureRaxBool(ctx, genExpr(ctx, n.a))
    ctx.emit("testq %rax, %rax")
    if n.c.isNil:
      let lEnd = ctx.newLabel()
      ctx.emit("jz " & lEnd)
      genStmt(ctx, n.b)
      ctx.emitLabel(lEnd)
    else:
      let lElse = ctx.newLabel()
      let lEnd = ctx.newLabel()
      ctx.emit("jz " & lElse)
      genStmt(ctx, n.b)
      ctx.emit("jmp " & lEnd)
      ctx.emitLabel(lElse)
      genStmt(ctx, n.c)
      ctx.emitLabel(lEnd)
  of nkWhile:
    let lStart = ctx.newLabel()
    let lEnd = ctx.newLabel()
    ctx.emitLabel(lStart)
    ensureRaxBool(ctx, genExpr(ctx, n.a))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jz " & lEnd)
    ctx.breakLabels.add lEnd
    ctx.continueLabels.add lStart
    genStmt(ctx, n.b)
    discard ctx.breakLabels.pop()
    discard ctx.continueLabels.pop()
    ctx.emit("jmp " & lStart)
    ctx.emitLabel(lEnd)
  of nkDoWhile:
    let lStart = ctx.newLabel()
    let lCond = ctx.newLabel()
    let lEnd = ctx.newLabel()
    ctx.emitLabel(lStart)
    ctx.breakLabels.add lEnd
    ctx.continueLabels.add lCond
    genStmt(ctx, n.b)
    discard ctx.breakLabels.pop()
    discard ctx.continueLabels.pop()
    ctx.emitLabel(lCond)
    ensureRaxBool(ctx, genExpr(ctx, n.a))
    ctx.emit("testq %rax, %rax")
    ctx.emit("jnz " & lStart)
    ctx.emitLabel(lEnd)
  of nkFor:
    pushScope(ctx)
    let lStart = ctx.newLabel()
    let lPost = ctx.newLabel()
    let lEnd = ctx.newLabel()
    if not n.a.isNil: genStmt(ctx, n.a)
    ctx.emitLabel(lStart)
    if not n.b.isNil:
      ensureRaxBool(ctx, genExpr(ctx, n.b))
      ctx.emit("testq %rax, %rax")
      ctx.emit("jz " & lEnd)
    ctx.breakLabels.add lEnd
    ctx.continueLabels.add lPost
    genStmt(ctx, n.d)
    discard ctx.breakLabels.pop()
    discard ctx.continueLabels.pop()
    ctx.emitLabel(lPost)
    if not n.c.isNil: discard genExpr(ctx, n.c)
    ctx.emit("jmp " & lStart)
    ctx.emitLabel(lEnd)
    popScope(ctx)
  of nkReturnStmt:
    if not n.a.isNil:
      if not ctx.curRetType.isNil and ctx.curRetType.kind in {tkStruct, tkUnion}:
        ctx.err(n, "zwracanie struct/union przez wartość nieobsługiwane w tej iteracji codegenu")
      discard genExpr(ctx, n.a)
    ctx.emit("jmp " & ctx.epilogueLabel)
  of nkBreakStmt:
    if ctx.breakLabels.len == 0: ctx.err(n, "'break' poza pętlą/switch")
    else: ctx.emit("jmp " & ctx.breakLabels[^1])
  of nkContinueStmt:
    if ctx.continueLabels.len == 0: ctx.err(n, "'continue' poza pętlą")
    else: ctx.emit("jmp " & ctx.continueLabels[^1])
  of nkGotoStmt:
    ctx.emit("jmp " & ctx.userLabel(n.strVal))
  of nkLabelStmt:
    ctx.emitLabel(ctx.userLabel(n.strVal))
    genStmt(ctx, n.a)
  of nkSwitchStmt:
    genSwitch(ctx, n)
  of nkCaseStmt:
    ctx.emitLabel(ctx.caseLabels[cast[pointer](n)])
    genStmt(ctx, n.b)
  of nkDefaultStmt:
    ctx.emitLabel(ctx.caseLabels[cast[pointer](n)])
    genStmt(ctx, n.a)
  of nkEmptyStmt: discard
  of nkDeclStmt:
    for d in n.list:
      case d.kind
      of nkVarDecl:
        let off = declareLocal(ctx, d.strVal, d.typ)
        if not d.a.isNil:
          genLocalInit(ctx, d.typ, off, d.a)
      of nkTypedefDecl, nkTagDecl: discard
      else: discard
  of nkStaticAssert:
    let (ok, v) = evalConstInt(n.a)
    if ok and v == 0:
      ctx.err(n, "_Static_assert nie powiodło się" & (if n.strVal.len > 0: ": " & n.strVal else: ""))
  else:
    ctx.err(n, "nieobsługiwany rodzaj instrukcji w codegenie: " & $n.kind)

# ============================== funkcje ==============================

## Klasyfikacja parametrów/argumentów wg SysV AMD64 ABI: dwa NIEZALEŻNE
## liczniki (int i float), przydzielane zachłannie lewo-prawo; to, co się
## nie zmieści w żadnym z limitów (6 int / 8 float), trafia na stos, W
## KOLEJNOŚCI DEKLARACJI wśród samych argumentów stosowych. Używane
## symetrycznie przez `genFunction` (odczyt parametrów) i
## `genArgsCommon` (przekazywanie argumentów przy wywołaniu) - MUSZĄ się
## zgadzać, bo klasyfikacja zależy WYŁĄCZNIE od typów w sygnaturze, nie
## od tego, co konkretnie jest przekazywane (tak działa prawdziwe SysV
## ABI - stąd dzielenie tej samej logiki, a nie dwóch niezależnych kopii).
proc classifyArgTypes(types: seq[CType]): tuple[intReg, fltReg, stackPos: seq[int],
                                                  nInt, nFlt, nStack: int] =
  let n = types.len
  result.intReg = newSeq[int](n)
  result.fltReg = newSeq[int](n)
  result.stackPos = newSeq[int](n)
  var nextInt = 0
  var nextFlt = 0
  var nextStack = 0
  for i in 0 ..< n:
    result.intReg[i] = -1
    result.fltReg[i] = -1
    result.stackPos[i] = -1
    if isFloatingType(types[i]):
      if nextFlt < 8: result.fltReg[i] = nextFlt; inc nextFlt
      else: result.stackPos[i] = nextStack; inc nextStack
    else:
      if nextInt < 6: result.intReg[i] = nextInt; inc nextInt
      else: result.stackPos[i] = nextStack; inc nextStack
  result.nInt = nextInt
  result.nFlt = nextFlt
  result.nStack = nextStack

proc genFunction(ctx: var CGCtx, n: Node) =
  if n.b.isNil: return
  ctx.curFuncName = n.strVal
  ctx.curRetType = n.typ.returnType
  ctx.scopes = @[initTable[string, LocalVar]()]
  ctx.frameUsed = 0
  ctx.pushDepth = 0
  ctx.epilogueLabel = ".Lepilogue_" & n.strVal
  ctx.breakLabels = @[]
  ctx.continueLabels = @[]

  if not ctx.curRetType.isNil and ctx.curRetType.kind in {tkStruct, tkUnion}:
    ctx.err(n, "funkcje zwracające struct/union przez wartość nieobsługiwane w tej iteracji codegenu")

  let savedOutp = ctx.outp
  ctx.outp = ""
  var paramTypes: seq[CType] = @[]
  for p in n.params: paramTypes.add p.typ
  let cls = classifyArgTypes(paramTypes)
  for i, p in n.params:
    if p.typ.kind in {tkStruct, tkUnion}:
      ctx.err(p, "parametry typu struct/union przekazywane przez wartość nieobsługiwane w tej iteracji codegenu")
    if cls.intReg[i] >= 0:
      let off = declareLocal(ctx, p.strVal, p.typ)
      let szRaw = typeSizeOf(p.typ)
      let sz = if szRaw in [1, 2, 4, 8]: szRaw else: 8
      ctx.emit("mov" & widthSuffix(sz) & " " & argRegFor(cls.intReg[i], sz) & ", " & $off & "(%rbp)")
    elif cls.fltReg[i] >= 0:
      let off = declareLocal(ctx, p.strVal, p.typ)
      if cls.fltReg[i] != 0:
        ctx.emit("movsd %xmm" & $cls.fltReg[i] & ", %xmm0")
      storeToMem(ctx, p.typ, $off & "(%rbp)")
    else:
      let callerOff = 16 + 8 * cls.stackPos[i]
      if p.strVal.len > 0:
        ctx.scopes[^1][p.strVal] = (callerOff, p.typ)
  for s in n.b.list: genStmt(ctx, s)
  if n.strVal == "main":
    ctx.emit("movq $0, %rax")  # C99+: main() bez jawnego return na końcu -> zwraca 0
  let bodyText = ctx.outp
  ctx.outp = savedOutp

  let frameSize = ((ctx.frameUsed + 15) div 16) * 16
  if n.storage != scStatic:
    ctx.outp.add ".globl " & n.strVal & "\n"
  ctx.outp.add ".type " & n.strVal & ", @function\n"
  ctx.emitLabel(n.strVal)
  ctx.emit("pushq %rbp")
  ctx.emit("movq %rsp, %rbp")
  if frameSize > 0:
    ctx.emit("subq $" & $frameSize & ", %rsp")
  ctx.outp.add bodyText
  ctx.emitLabel(ctx.epilogueLabel)
  ctx.emit("movq %rbp, %rsp")
  ctx.emit("popq %rbp")
  ctx.emit("ret")
  ctx.outp.add ".size " & n.strVal & ", . - " & n.strVal & "\n"

# ============================== zmienne globalne ==============================

## Stałe wyrażenia zmiennoprzecinkowe (inicjalizatory globalnych `float`/
## `double`) - osobno od `evalConstInt` w layout.nim (tamten jest czysto
## całkowitoliczbowy; tu potrzebujemy `parseFloatLiteralBits` i realnej
## arytmetyki double, więc zostaje w codegen.nim, bliżej miejsca użycia).
proc evalConstFloat(n: Node): tuple[ok: bool, val: float64] =
  if n.isNil: return (false, 0.0)
  case n.kind
  of nkFloatLit:
    (true, cast[float64](parseFloatLiteralBits(n.strVal)))
  of nkIntLit, nkCharLit:
    let (ok, v) = evalConstInt(n)
    (ok, float64(v))
  of nkUnaryPre:
    let (ok, v) = evalConstFloat(n.a)
    if not ok: return (false, 0.0)
    case n.op
    of "-": (true, -v)
    of "+": (true, v)
    else: (false, 0.0)
  of nkBinary:
    let (okA, a) = evalConstFloat(n.a)
    let (okB, b) = evalConstFloat(n.b)
    if not okA or not okB: return (false, 0.0)
    case n.op
    of "+": (true, a + b)
    of "-": (true, a - b)
    of "*": (true, a * b)
    of "/": (if b == 0.0: (false, 0.0) else: (true, a / b))
    else: (false, 0.0)
  of nkCast:
    evalConstFloat(n.a)
  else:
    (false, 0.0)

proc emitStaticInit(ctx: var CGCtx, ty: CType, init: Node, outBuf: var string) =
  if isFloatingType(ty):
    let (ok, v) = evalConstFloat(init)
    if not ok:
      ctx.err(init, "inicjalizator zmiennej globalnej musi być stałą w czasie kompilacji")
      outBuf.add "    .quad 0\n"
    elif ty.kind == tkFloat:
      outBuf.add "    .long 0x" & cast[uint32](float32(v)).toHex(8) & "\n"
    else:
      outBuf.add "    .quad 0x" & cast[uint64](v).toHex(16) & "\n"
  elif isScalarType(ty):
    if init.kind == nkStringLit and isPointerLikeType(ty):
      let lbl = ctx.internString(init.strVal)
      outBuf.add "    .quad " & lbl & "\n"
      return
    var actual = init
    if init.kind == nkInitList:
      if init.list.len == 0:
        outBuf.add "    ." & sizeDirective(typeSizeOf(ty)) & " 0\n"
        return
      actual = init.list[0]
    let (ok, v) = evalConstInt(actual)
    if not ok:
      ctx.err(init, "inicjalizator zmiennej globalnej musi być stałą w czasie kompilacji")
      outBuf.add "    ." & sizeDirective(typeSizeOf(ty)) & " 0\n"
    else:
      outBuf.add "    ." & sizeDirective(typeSizeOf(ty)) & " " & $v & "\n"
  elif ty.kind == tkArray:
    let elemTy = ty.elem
    let n = arrayLenOf(ty)
    if n < 0:
      ctx.err(init, "rozmiar tablicy nie jest stałą znaną w czasie kompilacji")
      return
    if init.kind == nkStringLit and not elemTy.isNil and elemTy.kind == tkChar:
      let bytes = decodeCString(init.strVal) & "\0"
      var parts: seq[string] = @[]
      for i in 0 ..< n:
        parts.add $(if i < bytes.len: ord(bytes[i]) else: 0)
      outBuf.add "    .byte " & parts.join(", ") & "\n"
    elif init.kind == nkInitList:
      for i in 0 ..< n:
        if i < init.list.len:
          emitStaticInit(ctx, elemTy, init.list[i], outBuf)
        else:
          outBuf.add "    .zero " & $typeSizeOf(elemTy) & "\n"
    else:
      ctx.err(init, "nieobsługiwany inicjalizator globalnej zmiennej tablicowej")
  elif ty.kind == tkUnion:
    let ufields = resolvedFields(ty)
    if init.kind != nkInitList or init.list.len == 0 or ufields.len == 0:
      ctx.err(init, "nieobsługiwany inicjalizator globalnej zmiennej union")
      return
    let f0 = ufields[0]
    emitStaticInit(ctx, f0.typ, init.list[0], outBuf)
    let used = typeSizeOf(f0.typ)
    let total = typeSizeOf(ty)
    if total > used: outBuf.add "    .zero " & $(total - used) & "\n"
  elif ty.kind == tkStruct:
    if init.kind != nkInitList:
      ctx.err(init, "nieobsługiwany inicjalizator globalnej zmiennej struct")
      return
    var pos = 0
    for i, f in resolvedFields(ty):
      let foff = fieldOffset(ty, f.name)
      if foff > pos:
        outBuf.add "    .zero " & $(foff - pos) & "\n"
      if i < init.list.len:
        emitStaticInit(ctx, f.typ, init.list[i], outBuf)
      else:
        outBuf.add "    .zero " & $typeSizeOf(f.typ) & "\n"
      pos = foff + typeSizeOf(f.typ)
    let total = typeSizeOf(ty)
    if total > pos: outBuf.add "    .zero " & $(total - pos) & "\n"
  else:
    ctx.err(init, "nieobsługiwany typ inicjalizowanej zmiennej globalnej: " & typeToString(ty))

proc genGlobalVar(ctx: var CGCtx, n: Node) =
  if n.storage == scExtern: return
  let sz = max(1, typeSizeOf(n.typ))
  let al = max(1, typeAlignOf(n.typ))
  if n.a.isNil:
    if n.storage != scStatic: ctx.bssOut.add ".globl " & n.strVal & "\n"
    ctx.bssOut.add ".align " & $al & "\n"
    ctx.bssOut.add n.strVal & ":\n"
    ctx.bssOut.add "    .zero " & $sz & "\n"
  else:
    if n.storage != scStatic: ctx.dataOut.add ".globl " & n.strVal & "\n"
    ctx.dataOut.add ".align " & $al & "\n"
    ctx.dataOut.add n.strVal & ":\n"
    emitStaticInit(ctx, n.typ, n.a, ctx.dataOut)

# ============================== enumy, typedeffy, sterowanie całością ==============================

proc computeEnumConsts(ctx: var CGCtx, unit: Node) =
  proc handleEnumType(ctx: var CGCtx, ty: CType) =
    if ty.isNil or ty.kind != tkEnum: return
    var next: int64 = 0
    for e in ty.enumerators:
      var v = next
      if not e.value.isNil:
        let (ok, cv) = evalConstInt(e.value)
        if ok: v = cv
        else: ctx.diags.add errAt(ctx.file, e.line, e.col,
          "wartość enumeratora '" & e.name & "' nie jest stałą całkowitą", 1, "")
      ctx.enumConsts[e.name] = v
      next = v + 1
  proc walk(ctx: var CGCtx, n: Node) =
    if n.isNil: return
    if n.kind == nkTagDecl: handleEnumType(ctx, n.typ)
    for c in [n.a, n.b, n.c, n.d]: walk(ctx, c)
    for c in n.list: walk(ctx, c)
    for p in n.params: walk(ctx, p)
  walk(ctx, unit)

proc collectSignatures(ctx: var CGCtx, unit: Node) =
  for d in unit.list:
    case d.kind
    of nkFuncDef, nkFuncDecl: ctx.funcSigs[d.strVal] = d.typ
    of nkVarDecl: ctx.globalVars[d.strVal] = d.typ
    else: discard

## Wypełnia `resolved` dla każdego napotkanego CType(kind=tkTypedefName)
## na podstawie tabeli nazw->typów zebranej z WSZYSTKICH `nkTypedefDecl`
## w całym drzewie (uproszczenie: jeden płaski, globalny zakres nazw
## typedef, nawet dla typedefów lokalnych - w praktyce prawie zawsze
## wystarczające, bo lokalne typedeffy o kolidujących nazwach są rzadkie;
## pełne poszanowanie zasięgu bloków to TODO). `layout.typeSizeOf` i
## reszta polegają na tym, że ten przebieg wykonał się PRZED codegenem.
## Wypełnia `resolved` dla:
## 1. każdego napotkanego CType(kind=tkTypedefName) - na podstawie tabeli
##    nazw->typów zebranej z WSZYSTKICH `nkTypedefDecl` w drzewie;
## 2. każdego NIEKOMPLETNEGO struct/union/enum (sam tag bez ciała) - na
##    podstawie tabeli (kind,tag)->KOMPLETNY typ, zebranej z każdego
##    napotkanego CType tego samego rodzaju, który MA ciało. Bez tego
##    `struct Point p;` (odwołanie do tagu zdefiniowanego gdzie indziej,
##    bez ponownego `{ ... }`) dostawałoby pusty, bezużyteczny typ - patrz
##    komentarz przy `resolveTypedef` w layout.nim.
## Uproszczenie (jak przy typedefach): jeden płaski, globalny zakres nazw
## tagów, nawet dla tagów lokalnych - pełne poszanowanie zasięgu bloków
## to TODO. `layout.typeSizeOf`/`fieldOffset`/... polegają na tym, że ten
## przebieg wykonał się PRZED codegenem.
proc resolveAllTypedefs(unit: Node) =
  var typedefTable = initTable[string, CType]()
  var tagTable = initTable[string, CType]()  # klucz: "struct:Name" / "union:Name" / "enum:Name"
  proc tagKey(t: CType): string =
    (case t.kind
     of tkStruct: "struct:"
     of tkUnion: "union:"
     else: "enum:") & t.tag

  var seenForCollect = initHashSet[pointer]()
  proc collectCType(t: CType) =
    if t.isNil: return
    let p = cast[pointer](t)
    if p in seenForCollect: return
    seenForCollect.incl p
    if t.kind in {tkStruct, tkUnion, tkEnum} and t.tag.len > 0 and t.isComplete:
      let k = tagKey(t)
      if k notin tagTable: tagTable[k] = t
    collectCType(t.pointee)
    collectCType(t.elem)
    collectCType(t.returnType)
    for pt in t.paramTypes: collectCType(pt)
    for f in t.fields: collectCType(f.typ)
  proc collect(n: Node) =
    if n.isNil: return
    if n.kind == nkTypedefDecl: typedefTable[n.strVal] = n.typ
    collectCType(n.typ)
    for c in [n.a, n.b, n.c, n.d]: collect(c)
    for c in n.list: collect(c)
    for p in n.params: collect(p)
  collect(unit)

  var visited = initHashSet[pointer]()
  proc walkCType(t: CType) =
    if t.isNil: return
    let p = cast[pointer](t)
    if p in visited: return
    visited.incl p
    if t.kind == tkTypedefName and t.resolved.isNil and t.tag in typedefTable:
      t.resolved = typedefTable[t.tag]
    elif t.kind in {tkStruct, tkUnion, tkEnum} and not t.isComplete and
         t.resolved.isNil and t.tag.len > 0:
      let k = tagKey(t)
      if k in tagTable: t.resolved = tagTable[k]
    walkCType(t.pointee)
    walkCType(t.elem)
    walkCType(t.returnType)
    for pt in t.paramTypes: walkCType(pt)
    for f in t.fields: walkCType(f.typ)
  proc walkNode(n: Node) =
    if n.isNil: return
    walkCType(n.typ)
    for prm in n.params: walkNode(prm)
    for c in [n.a, n.b, n.c, n.d]: walkNode(c)
    for c in n.list: walkNode(c)
  walkNode(unit)

## Zamienia w AST każde użycie znanej stałej wyliczeniowej (nkIdent o
## nazwie z `enumConsts`) na literał całkowity (nkIntLit) - w miejscu,
## mutując węzeł. Musi zajść PO `computeEnumConsts` (potrzebuje gotowej
## tabeli wartości) i PRZED resztą codegenu (żeby `evalConstInt` -
## używane m.in. do etykiet `case` i rozmiarów tablic - widziało stałe
## enuma jako zwykłe liczby, bez konieczności przeciągania osobnej tabeli
## symboli przez cały layout.nim). Uproszczenie: jeden płaski, globalny
## zakres nazw enumeratorów - zmienna/parametr o tej samej nazwie co
## stała enuma (bardzo rzadkie w praktyce) zostanie błędnie podmieniona;
## udokumentowane ograniczenie, spójne z tym samym uproszczeniem przy
## typedefach i tagach wyżej.
proc foldEnumConstants(unit: Node, enumConsts: Table[string, int64]) =
  proc fold(n: Node) =
    if n.isNil: return
    if n.kind == nkIdent and n.strVal in enumConsts:
      n.kind = nkIntLit
      n.strVal = $enumConsts[n.strVal]
    else:
      for c in [n.a, n.b, n.c, n.d]: fold(c)
      for c in n.list: fold(c)
      for p in n.params: fold(p)
      if not n.typ.isNil:
        for f in n.typ.enumerators:
          fold(f.value)
        if not n.typ.arrayLen.isNil: fold(n.typ.arrayLen)
  fold(unit)

proc generateModule*(unit: Node, file: string): tuple[asmText: string, diags: seq[Diagnostic]] =
  var ctx = CGCtx(file: file)
  ctx.funcSigs = initTable[string, CType]()
  ctx.globalVars = initTable[string, CType]()
  ctx.enumConsts = initTable[string, int64]()
  ctx.caseLabels = initTable[pointer, string]()

  resolveAllTypedefs(unit)
  collectSignatures(ctx, unit)
  computeEnumConsts(ctx, unit)
  foldEnumConstants(unit, ctx.enumConsts)

  for d in unit.list:
    case d.kind
    of nkFuncDef: genFunction(ctx, d)
    of nkVarDecl: genGlobalVar(ctx, d)
    else: discard

  var final = "    .text\n" & ctx.outp
  if ctx.dataOut.len > 0: final.add "\n    .data\n" & ctx.dataOut
  if ctx.bssOut.len > 0: final.add "\n    .bss\n" & ctx.bssOut
  if ctx.rodataOut.len > 0: final.add "\n    .section .rodata\n" & ctx.rodataOut
  final.add "\n    .section .note.GNU-stack,\"\",@progbits\n"
  result = (final, ctx.diags)
