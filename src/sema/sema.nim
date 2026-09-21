import std/tables
import ../diagnostics
import ../parser/ast

type
  SymKind = enum skVar, skFunc, skTypedefName, skEnumConst, skTag

  Sym = object
    kind: SymKind
    typ: CType
    line, col: int

  Scope = ref object
    syms: Table[string, Sym]
    parent: Scope

  SemaCtx = object
    file: string
    diags: seq[Diagnostic]
    global: Scope
    cur: Scope
    loopDepth: int
    switchDepth: int
    curFunc: Node          # bieżąca definicja funkcji (do sprawdzania return) albo nil

proc newScope(parent: Scope): Scope = Scope(syms: initTable[string, Sym](), parent: parent)

proc lookup(s: Scope, name: string): ptr Sym =
  var cur = s
  while cur != nil:
    if name in cur.syms: return addr cur.syms[name]
    cur = cur.parent
  nil

proc lookupLocal(s: Scope, name: string): ptr Sym =
  if name in s.syms: return addr s.syms[name]
  nil

proc semaErr(ctx: var SemaCtx, line, col: int, msg: string, suggestion = "") =
  ctx.diags.add errAt(ctx.file, line, col, msg, 1, suggestion)

proc semaWarn(ctx: var SemaCtx, line, col: int, msg: string) =
  ctx.diags.add warnAt(ctx.file, line, col, msg)

## Prosta odległość Levenshteina - do sugestii "czy chodziło o..." przy
## nieznanych identyfikatorach. Celowo naiwna implementacja O(n*m) -
## nazwy identyfikatorów w C są krótkie, wydajność nie jest tu problemem.
proc editDistance(a, b: string): int =
  let n = a.len
  let m = b.len
  var prev = newSeq[int](m + 1)
  var cur = newSeq[int](m + 1)
  for j in 0 .. m: prev[j] = j
  for i in 1 .. n:
    cur[0] = i
    for j in 1 .. m:
      let cost = if a[i-1] == b[j-1]: 0 else: 1
      cur[j] = min(min(prev[j] + 1, cur[j-1] + 1), prev[j-1] + cost)
    prev = cur
  prev[m]

## Szuka w widocznych zakresach nazwy najbliższej `name` (odległość <= 2),
## do sugestii diagnostycznej. Zwraca "" jeśli nic sensownego nie znaleziono.
proc suggestSimilar(ctx: SemaCtx, name: string): string =
  var best = ""
  var bestDist = 3
  var s = ctx.cur
  while s != nil:
    for k in s.syms.keys:
      if k == name: continue
      let d = editDistance(name, k)
      if d < bestDist:
        bestDist = d
        best = k
    s = s.parent
  best

proc declare(ctx: var SemaCtx, name: string, kind: SymKind, typ: CType, line, col: int) =
  if name.len == 0: return
  let existing = lookupLocal(ctx.cur, name)
  if existing != nil:
    # dopuszczamy powtórną deklarację funkcji o tej samej "kształtowej"
    # zgodności (prototyp -> prototyp, prototyp -> definicja) - nie
    # sprawdzamy pełnej zgodności sygnatur (TODO), tylko blokujemy
    # ewidentny konflikt kind (np. zmienna po funkcji o tej samej nazwie)
    if existing.kind != kind:
      ctx.semaErr(line, col, "redefinicja '" & name &
        "' z innym rodzajem symbolu niż poprzednia deklaracja")
    elif kind == skVar:
      ctx.semaErr(line, col, "redefinicja zmiennej '" & name & "'",
        "poprzednia deklaracja: linia " & $existing.line)
    # dla funkcji: cicho nadpisujemy (typowy przypadek: deklaracja/prototyp -> definicja)
    ctx.cur.syms[name] = Sym(kind: kind, typ: typ, line: line, col: col)
  else:
    ctx.cur.syms[name] = Sym(kind: kind, typ: typ, line: line, col: col)

# forward declarations
proc checkExpr(ctx: var SemaCtx, n: Node)
proc checkStmt(ctx: var SemaCtx, n: Node)

## Rejestruje tag (struct/union/enum) w bieżącym zakresie i, dla enumów,
## dodatkowo każdą wartość wyliczeniową jako osobny symbol skEnumConst -
## w C stałe enuma żyją w przestrzeni nazw zwykłych identyfikatorów
## (inaczej niż sam tag), więc `enum Color c = GREEN;` musi widzieć GREEN.
proc declareTag(ctx: var SemaCtx, typ: CType, line, col: int) =
  if typ.isNil: return
  if typ.tag.len > 0:
    ctx.declare(typ.tag, skTag, typ, line, col)
  if typ.kind == tkEnum:
    for e in typ.enumerators:
      if not e.value.isNil: checkExpr(ctx, e.value)
      ctx.declare(e.name, skEnumConst, typ, e.line, e.col)

proc checkExprList(ctx: var SemaCtx, ns: seq[Node]) =
  for e in ns:
    if not e.isNil: checkExpr(ctx, e)

proc checkExpr(ctx: var SemaCtx, n: Node) =
  if n.isNil: return
  case n.kind
  of nkIntLit, nkFloatLit, nkCharLit, nkStringLit: discard
  of nkIdent:
    let sym = lookup(ctx.cur, n.strVal)
    if sym == nil:
      let sug = ctx.suggestSimilar(n.strVal)
      let suggestion = if sug.len > 0: "czy chodziło o '" & sug & "'?" else: ""
      ctx.semaErr(n.line, n.col, "nieznany identyfikator '" & n.strVal & "'", suggestion)
    else:
      n.typ = sym.typ
  of nkBinary:
    checkExpr(ctx, n.a); checkExpr(ctx, n.b)
  of nkAssign:
    checkExpr(ctx, n.a); checkExpr(ctx, n.b)
    if n.a.kind notin {nkIdent, nkIndex, nkMember, nkArrow, nkUnaryPre}:
      ctx.semaErr(n.line, n.col, "lewa strona przypisania nie jest l-wartością")
  of nkUnaryPre, nkUnaryPost:
    checkExpr(ctx, n.a)
  of nkCond:
    checkExpr(ctx, n.a); checkExpr(ctx, n.b); checkExpr(ctx, n.c)
  of nkCall:
    checkExpr(ctx, n.a)
    checkExprList(ctx, n.list)
    if n.a.kind == nkIdent:
      let sym = lookup(ctx.cur, n.a.strVal)
      if sym != nil and sym.kind == skFunc and not sym.typ.isNil and
         sym.typ.kind == tkFunction and sym.typ.hasKnownParams:
        let expected = sym.typ.paramTypes.len
        let got = n.list.len
        if got < expected or (got > expected and not sym.typ.isVariadic):
          ctx.semaErr(n.line, n.col, "funkcja '" & n.a.strVal & "' oczekuje " &
            $expected & " argumentów, podano " & $got)
  of nkIndex:
    checkExpr(ctx, n.a); checkExpr(ctx, n.b)
  of nkMember, nkArrow:
    checkExpr(ctx, n.a)
    # Sprawdzenie istnienia pola wymaga w pełni rozwiązanego typu structa
    # (w tym przez typedef) - odłożone na moment, gdy sema będzie miała
    # pełne środowisko typów (tagi + typedeffy rozwiązane w jednym
    # przebiegu). Na tym etapie: brak walidacji nazwy pola (TODO).
    discard
  of nkCast:
    checkExpr(ctx, n.a)
  of nkSizeofExpr:
    checkExpr(ctx, n.a)
  of nkSizeofType: discard
  of nkComma, nkInitList:
    checkExprList(ctx, n.list)
  else:
    discard  # nie-wyrażeniowy NodeKind trafił tu przez pomyłkę wołającego - ignorujemy

proc declareParams(ctx: var SemaCtx, params: seq[Node]) =
  for prm in params:
    if prm.strVal.len > 0:
      ctx.declare(prm.strVal, skVar, prm.typ, prm.line, prm.col)

proc checkStmt(ctx: var SemaCtx, n: Node) =
  if n.isNil: return
  case n.kind
  of nkCompound:
    let saved = ctx.cur
    ctx.cur = newScope(saved)
    for s in n.list: checkStmt(ctx, s)
    ctx.cur = saved
  of nkExprStmt:
    checkExpr(ctx, n.a)
  of nkIf:
    checkExpr(ctx, n.a); checkStmt(ctx, n.b); checkStmt(ctx, n.c)
  of nkWhile, nkDoWhile:
    checkExpr(ctx, n.a)
    inc ctx.loopDepth
    checkStmt(ctx, n.b)
    dec ctx.loopDepth
  of nkFor:
    let saved = ctx.cur
    ctx.cur = newScope(saved)
    if not n.a.isNil: checkStmt(ctx, n.a)
    if not n.b.isNil: checkExpr(ctx, n.b)
    if not n.c.isNil: checkExpr(ctx, n.c)
    inc ctx.loopDepth
    checkStmt(ctx, n.d)
    dec ctx.loopDepth
    ctx.cur = saved
  of nkReturnStmt:
    if not n.a.isNil: checkExpr(ctx, n.a)
    if not ctx.curFunc.isNil and not ctx.curFunc.typ.isNil:
      let retTy = ctx.curFunc.typ.returnType
      if not retTy.isNil and retTy.kind == tkVoid and not n.a.isNil:
        ctx.semaWarn(n.line, n.col, "'return' z wartością w funkcji zwracającej void")
      elif not retTy.isNil and retTy.kind != tkVoid and n.a.isNil:
        ctx.semaWarn(n.line, n.col, "'return' bez wartości w funkcji zwracającej " &
          typeToString(retTy))
  of nkBreakStmt:
    if ctx.loopDepth == 0 and ctx.switchDepth == 0:
      ctx.semaErr(n.line, n.col, "'break' poza pętlą lub switch")
  of nkContinueStmt:
    if ctx.loopDepth == 0:
      ctx.semaErr(n.line, n.col, "'continue' poza pętlą")
  of nkGotoStmt: discard  ## sprawdzenie istnienia etykiety: TODO (wymaga dwuprzebiegowego zbierania etykiet)
  of nkLabelStmt:
    checkStmt(ctx, n.a)
  of nkSwitchStmt:
    checkExpr(ctx, n.a)
    inc ctx.switchDepth
    checkStmt(ctx, n.b)
    dec ctx.switchDepth
  of nkCaseStmt:
    checkExpr(ctx, n.a)
    checkStmt(ctx, n.b)
  of nkDefaultStmt:
    checkStmt(ctx, n.a)
  of nkEmptyStmt: discard
  of nkDeclStmt:
    for d in n.list:
      case d.kind
      of nkVarDecl:
        if not d.a.isNil: checkExpr(ctx, d.a)
        ctx.declare(d.strVal, skVar, d.typ, d.line, d.col)
      of nkTypedefDecl:
        ctx.declare(d.strVal, skTypedefName, d.typ, d.line, d.col)
      of nkTagDecl:
        ctx.declareTag(d.typ, d.line, d.col)
      else: discard
  of nkStaticAssert:
    checkExpr(ctx, n.a)
  else:
    discard

proc checkTopDecl(ctx: var SemaCtx, n: Node) =
  case n.kind
  of nkTypedefDecl:
    ctx.declare(n.strVal, skTypedefName, n.typ, n.line, n.col)
  of nkTagDecl:
    ctx.declareTag(n.typ, n.line, n.col)
  of nkVarDecl:
    ctx.declare(n.strVal, skVar, n.typ, n.line, n.col)
    if not n.a.isNil: checkExpr(ctx, n.a)
  of nkFuncDecl:
    ctx.declare(n.strVal, skFunc, n.typ, n.line, n.col)
  of nkFuncDef:
    ctx.declare(n.strVal, skFunc, n.typ, n.line, n.col)
    let saved = ctx.cur
    ctx.cur = newScope(saved)
    let savedFunc = ctx.curFunc
    ctx.curFunc = n
    ctx.declareParams(n.params)
    checkStmt(ctx, n.b)
    ctx.curFunc = savedFunc
    ctx.cur = saved
  of nkStaticAssert:
    checkExpr(ctx, n.a)
  else:
    discard

## Punkt wejścia: sprawdza cały nkTranslationUnit, zwraca zebrane diagnostyki.
## Nie mutuje/nie waliduje wejścia poza doklejaniem `typ` do rozwiązanych
## nkIdent - bezpieczne wołać wielokrotnie / w narzędziach (np. plugin API,
## patrz ROADMAP: `zcc_plugin_check_ast` czeka właśnie na to wejście).
proc runSema*(unit: Node, file: string): seq[Diagnostic] =
  var ctx = SemaCtx(file: file, diags: @[], loopDepth: 0, switchDepth: 0, curFunc: nil)
  ctx.global = newScope(nil)
  ctx.cur = ctx.global
  for d in unit.list:
    checkTopDecl(ctx, d)
  result = ctx.diags
