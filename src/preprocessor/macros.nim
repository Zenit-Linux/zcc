import std/[tables, strutils]
import pp_lexer

type
  MacroKind* = enum mkObject, mkFunction

  MacroDef* = object
    name*: string
    kind*: MacroKind
    params*: seq[string]
    variadic*: bool          ## obsługa __VA_ARGS__ (C99+) / __VA_OPT__ (C23, TODO)
    body*: seq[PpToken]

  MacroTable* = object
    macros: Table[string, MacroDef]

proc newMacroTable*(): MacroTable = MacroTable(macros: initTable[string, MacroDef]())

proc define*(mt: var MacroTable, def: MacroDef) = mt.macros[def.name] = def
proc undef*(mt: var MacroTable, name: string) = mt.macros.del(name)
proc isDefined*(mt: MacroTable, name: string): bool = mt.macros.hasKey(name)
proc get*(mt: MacroTable, name: string): MacroDef = mt.macros[name]

## Rozdziela argumenty wywołania makra funkcyjnego, respektując zagnieżdżone
## nawiasy (np. `f(g(a,b), c)` to dwa argumenty, nie cztery).
proc splitArgs*(toks: seq[PpToken]): seq[seq[PpToken]] =
  result = @[]
  if toks.len == 0: return
  var depth = 0
  var cur: seq[PpToken] = @[]
  for t in toks:
    if t.kind == ptPunct and t.text == "(": inc depth
    elif t.kind == ptPunct and t.text == ")": dec depth
    if t.kind == ptPunct and t.text == "," and depth == 0:
      result.add cur
      cur = @[]
    else:
      cur.add t
  result.add cur

proc stringify*(toks: seq[PpToken]): PpToken =
  ## Operator `#` - łączy tokeny argumentu w jeden literał string,
  ## z pojedynczą spacją tam, gdzie w źródle był jakikolwiek biały znak.
  var parts: seq[string] = @[]
  for i, t in toks:
    if i > 0 and t.spaceBefore: parts.add " "
    parts.add t.text.replace("\\", "\\\\").replace("\"", "\\\"")
  let line = if toks.len > 0: toks[0].line else: 0
  let col = if toks.len > 0: toks[0].col else: 0
  PpToken(kind: ptString, text: "\"" & parts.join("") & "\"", line: line, col: col)

proc pasteTokens*(a, b: PpToken): PpToken =
  ## Operator `##` - sklejenie leksykalne dwóch tokenów w jeden nowy.
  ## TODO: zweryfikować że wynik jest poprawnym pojedynczym pp-tokenem
  ## (standard tego wymaga - dziś nie ma tu walidacji, tylko konkatenacja).
  PpToken(kind: ptOther, text: a.text & b.text, line: a.line, col: a.col)

## Zestaw "już rozwiniętych na tej ścieżce" nazw makr, przekazywany przez
## wywołania rekurencyjne expand() - trzymany jako osobny parametr (set),
## nie w samym PpToken, żeby nie zaśmiecać typu tokena używanego też przez
## resztę preprocesora.
proc expand*(mt: MacroTable, input: seq[PpToken], activeSet: var seq[string]): seq[PpToken]

proc expandOne(mt: MacroTable, toks: seq[PpToken], idx: int,
               activeSet: var seq[string]): tuple[expanded: seq[PpToken], consumed: int] =
  let t = toks[idx]
  if t.kind != ptIdent or not mt.isDefined(t.text) or t.text in activeSet:
    return (@[t], 1)

  let def = mt.get(t.text)

  if def.kind == mkObject:
    activeSet.add def.name
    var body = expand(mt, def.body, activeSet)
    discard activeSet.pop()
    return (body, 1)

  # makro funkcyjne - wymaga '(' zaraz po nazwie (pomijając nic, bo
  # pp-tokeny już mają usunięte białe znaki jako osobne tokeny)
  if idx + 1 >= toks.len or toks[idx+1].kind != ptPunct or toks[idx+1].text != "(":
    return (@[t], 1)  # nazwa bez wywołania - zostaje jako zwykły identyfikator

  # znajdź pasujący ')' i zbierz argumenty
  var depth = 0
  var j = idx + 1
  var argToks: seq[PpToken] = @[]
  while j < toks.len:
    let tj = toks[j]
    if tj.kind == ptPunct and tj.text == "(": inc depth
    elif tj.kind == ptPunct and tj.text == ")":
      dec depth
      if depth == 0:
        break
    if depth >= 1 and not (tj.kind == ptPunct and tj.text == "(" and depth == 1):
      argToks.add tj
    inc j
  # argToks zawiera wszystko między pierwszym '(' a dopasowanym ')'
  argToks = toks[idx+2 ..< j]
  let consumed = j - idx + 1

  var rawArgs = splitArgs(argToks)
  if rawArgs.len == 1 and rawArgs[0].len == 0 and def.params.len == 0:
    rawArgs = @[]

  var argMap = initTable[string, seq[PpToken]]()
  for i, p in def.params:
    if i < rawArgs.len: argMap[p] = rawArgs[i]
    else: argMap[p] = @[]
  if def.variadic:
    var va: seq[PpToken] = @[]
    for i in def.params.len ..< rawArgs.len:
      if va.len > 0: va.add PpToken(kind: ptPunct, text: ",")
      va.add rawArgs[i]
    argMap["__VA_ARGS__"] = va

  # podstawienie parametrów w ciele, z obsługą `#param` i `a ## b`
  var substituted: seq[PpToken] = @[]
  var k = 0
  while k < def.body.len:
    let bt = def.body[k]
    if bt.kind == ptHash and k+1 < def.body.len and def.body[k+1].kind == ptIdent and
       argMap.hasKey(def.body[k+1].text):
      substituted.add stringify(argMap[def.body[k+1].text])
      k += 2
      continue
    if bt.kind == ptIdent and argMap.hasKey(bt.text):
      # argument rozwijany rekurencyjnie PRZED wstawieniem, chyba że
      # sąsiaduje z ## (wtedy standard mówi: bez rozwijania) - uproszczone:
      # sprawdzamy sąsiedztwo ## po obu stronach
      let pastedLeft = k > 0 and substituted.len > 0 and
                        def.body[k-1].kind == ptHashHash
      let pastedRight = k+1 < def.body.len and def.body[k+1].kind == ptHashHash
      if pastedLeft or pastedRight:
        substituted.add argMap[bt.text]
      else:
        var inner = activeSet
        substituted.add expand(mt, argMap[bt.text], inner)
      k += 1
      continue
    substituted.add bt
    k += 1

  # operator ## - sklejanie sąsiednich tokenów w substituted
  var pasted: seq[PpToken] = @[]
  var m = 0
  while m < substituted.len:
    if substituted[m].kind == ptHashHash:
      if pasted.len > 0 and m+1 < substituted.len:
        let merged = pasteTokens(pasted[^1], substituted[m+1])
        pasted[^1] = merged
        m += 2
        continue
      else:
        m += 1
        continue
    pasted.add substituted[m]
    inc m

  activeSet.add def.name
  let finalExpanded = expand(mt, pasted, activeSet)
  discard activeSet.pop()
  return (finalExpanded, consumed)

proc expand*(mt: MacroTable, input: seq[PpToken], activeSet: var seq[string]): seq[PpToken] =
  result = @[]
  var i = 0
  while i < input.len:
    let (exp, consumed) = expandOne(mt, input, i, activeSet)
    result.add exp
    i += consumed
