import std/strutils
import ../parser/ast

proc typeAlignOf*(t: CType): int
proc typeSizeOf*(t: CType): int
proc evalConstInt*(n: Node): tuple[ok: bool, val: int64]

proc resolveTypedef(t: CType): CType =
  ## Podąża przez łańcuch `resolved` aż do konkretnego typu - obsługuje
  ## DWA rodzaje "kikutów" wypełnianych przed codegenem (patrz
  ## `resolveAllTypedefs` w codegen.nim):
  ## 1. tkTypedefName -> docelowy typ (zwykły alias `typedef`)
  ## 2. struct/union/enum niekompletny (isComplete=false, bo w miejscu
  ##    użycia podano sam tag bez ciała, np. `struct Point p;` po
  ##    wcześniejszym `struct Point { ... };` gdzie indziej) -> ta sama
  ##    struktura/enum, ale z wypełnionym `fields`/`enumerators`.
  ## Bez tego drugiego przypadku KAŻDE odwołanie do wcześniej
  ## zdefiniowanego tagu bez ponownego podania ciała tworzyłoby pusty,
  ## bezużyteczny typ (parser tworzy nową instancję CType przy każdym
  ## wystąpieniu `struct Nazwa` - patrz `parseStructOrUnionSpecifier`).
  result = t
  while not result.isNil:
    if result.kind == tkTypedefName and not result.resolved.isNil:
      result = result.resolved
    elif result.kind in {tkStruct, tkUnion, tkEnum} and not result.isComplete and
         not result.resolved.isNil:
      result = result.resolved
    else:
      break

proc typeAlignOf*(t: CType): int =
  let rt = resolveTypedef(t)
  if rt.isNil: return 1
  case rt.kind
  of tkVoid: 1
  of tkBool, tkChar: 1
  of tkShort: 2
  of tkInt, tkFloat: 4
  of tkLong, tkLongLong, tkDouble, tkLongDouble, tkPointer: 8
  of tkArray: typeAlignOf(rt.elem)
  of tkFunction: 8
  of tkEnum: 4
  of tkStruct, tkUnion:
    var m = 1
    for f in rt.fields:
      m = max(m, typeAlignOf(f.typ))
    max(m, 1)
  of tkTypedefName: 8  # nierozwiązany typedef (błąd gdzie indziej) - bezpieczny fallback
  of tkError: 1

## Długość tablicy (liczba elementów) - stała wynikająca z wyrażenia
## rozmiaru w deklaracji. -1 jeśli nie da się policzyć w czasie
## kompilacji (VLA albo błędne wyrażenie) - wołający zgłasza wtedy błąd.
proc arrayLenOf*(t: CType): int =
  if t.arrayLen.isNil: return -1
  let (ok, v) = evalConstInt(t.arrayLen)
  if not ok or v < 0: -1 else: int(v)

proc typeSizeOf*(t: CType): int =
  let rt = resolveTypedef(t)
  if rt.isNil: return 0
  case rt.kind
  of tkVoid: 0
  of tkBool, tkChar: 1
  of tkShort: 2
  of tkInt, tkFloat: 4
  of tkLong, tkLongLong, tkDouble, tkPointer: 8
  of tkLongDouble: 16
  of tkFunction: 8  # jako wartość (adres funkcji) - sam typ funkcji nie jest "przechowywalny"
  of tkEnum: 4
  of tkArray:
    let n = arrayLenOf(rt)
    if n < 0: 0 else: typeSizeOf(rt.elem) * n
  of tkStruct:
    var offset = 0
    for f in rt.fields:
      let a = typeAlignOf(f.typ)
      offset = ((offset + a - 1) div a) * a
      offset += typeSizeOf(f.typ)
    let al = typeAlignOf(rt)
    ((offset + al - 1) div al) * al
  of tkUnion:
    var m = 0
    for f in rt.fields:
      m = max(m, typeSizeOf(f.typ))
    let al = typeAlignOf(rt)
    ((m + al - 1) div al) * al
  of tkTypedefName: 8
  of tkError: 0

## Offset pola o danej nazwie w struct/union (liczony tak samo jak w
## `typeSizeOf` dla tkStruct - stąd oba muszą pozostać spójne, jeśli
## jedno się zmieni). Zwraca -1, jeśli pole nie istnieje.
proc fieldOffset*(t: CType, name: string): int =
  let rt = resolveTypedef(t)
  if rt.isNil or rt.kind notin {tkStruct, tkUnion}: return -1
  if rt.kind == tkUnion:
    for f in rt.fields:
      if f.name == name: return 0
    return -1
  var offset = 0
  for f in rt.fields:
    let a = typeAlignOf(f.typ)
    offset = ((offset + a - 1) div a) * a
    if f.name == name: return offset
    offset += typeSizeOf(f.typ)
  -1

proc fieldType*(t: CType, name: string): CType =
  let rt = resolveTypedef(t)
  if rt.isNil or rt.kind notin {tkStruct, tkUnion}: return nil
  for f in rt.fields:
    if f.name == name: return f.typ
  nil

## Lista pól struct/union PO rozwiązaniu ewentualnego niekompletnego
## "kikuta" (patrz `resolveTypedef` wyżej) - kikut sam w sobie ma `fields`
## puste (bo parsowano go bez ciała), więc kod iterujący pola MUSI
## przejść przez to rozwiązanie, inaczej pętla wykona się zero razy i
## po cichu nic nie zainicjalizuje/nie skopiuje. Realny bug znaleziony
## przy pierwszym teście inicjalizacji struktury z polami `double`.
proc resolvedFields*(t: CType): seq[Field] =
  let rt = resolveTypedef(t)
  if rt.isNil: return @[]
  rt.fields

## Czy typ jest "skalarny" w sensie tej iteracji codegenu (tj. mieści
## się w jednym rejestrze - ogólnego przeznaczenia dla int/wskaźnik/enum,
## XMM dla float/double) - struct/union/tablica NIE (wymagają adresu,
## nie pojedynczej wartości w rejestrze).
proc isScalarType*(t: CType): bool =
  let rt = resolveTypedef(t)
  if rt.isNil: return false
  rt.kind in {tkBool, tkChar, tkShort, tkInt, tkLong, tkLongLong, tkPointer, tkEnum,
              tkFloat, tkDouble, tkLongDouble}

proc isFloatingType*(t: CType): bool =
  let rt = resolveTypedef(t)
  not rt.isNil and rt.kind in {tkFloat, tkDouble, tkLongDouble}

proc isUnsignedType*(t: CType): bool =
  let rt = resolveTypedef(t)
  not rt.isNil and rt.isUnsigned

proc isPointerLikeType*(t: CType): bool =
  let rt = resolveTypedef(t)
  not rt.isNil and rt.kind in {tkPointer, tkArray}

## Typ, przez jaki faktycznie porusza się arytmetyka wskaźnikowa/tablicowa
## (`arr[i]`, `p + i`, dekrement typu tablicy do wskaźnika w wyrażeniach).
proc pointeeOf*(t: CType): CType =
  let rt = resolveTypedef(t)
  if rt.isNil: return nil
  case rt.kind
  of tkPointer: rt.pointee
  of tkArray: rt.elem
  else: nil

# ============================== ewaluator stałych ==============================

## Ewaluuje wyrażenie stałe całkowite (rozmiary tablic, wartości
## enumeratorów, etykiety `case`, warunki `_Static_assert`). Zwraca
## (false, 0), jeśli wyrażenie nie jest stałą całkowitą w tej uproszczonej
## definicji "stałej" - obejmuje to m.in. wywołania funkcji, dostęp do
## zmiennych (poza enumeratorami - te NIE są tu obsługiwane, bo wymagałyby
## dostępu do tabeli symboli sema/codegenu; `evalConstIntWithEnv` niżej
## to rozszerzenie o taką tabelę).
proc evalConstInt*(n: Node): tuple[ok: bool, val: int64] =
  if n.isNil: return (false, 0'i64)
  case n.kind
  of nkIntLit:
    # tekst tokenu może mieć sufiksy (u/U/l/L/ll/LL) i prefiksy 0x/0/0b -
    # parseInt-podobna, ręczna obsługa, bo std/strutils.parseInt nie
    # rozumie sufiksów C.
    var s = n.strVal
    while s.len > 0 and s[^1] in {'u', 'U', 'l', 'L'}: s.setLen(s.len - 1)
    if s.len == 0: return (false, 0'i64)
    try:
      var v: int64
      if s.len > 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X'):
        v = int64(parseHexInt(s))
      elif s.len > 2 and s[0] == '0' and (s[1] == 'b' or s[1] == 'B'):
        v = int64(parseBinInt(s))
      elif s.len > 1 and s[0] == '0':
        v = int64(parseOctInt(s))
      else:
        v = parseBiggestInt(s)
      (true, v)
    except ValueError:
      (false, 0'i64)
  of nkCharLit:
    let s = n.strVal
    if s.len >= 3 and s[0] == '\'':
      let inner = s[1 ..< s.len-1]
      if inner.len == 1: (true, int64(inner[0]))
      elif inner.len >= 2 and inner[0] == '\\':
        let c = case inner[1]
          of 'n': '\n'
          of 't': '\t'
          of 'r': '\r'
          of '0': '\0'
          of '\\': '\\'
          of '\'': '\''
          of '"': '"'
          else: inner[1]
        (true, int64(c))
      else: (false, 0'i64)
    else: (false, 0'i64)
  of nkUnaryPre:
    let (ok, v) = evalConstInt(n.a)
    if not ok: return (false, 0'i64)
    case n.op
    of "-": (true, -v)
    of "+": (true, v)
    of "~": (true, not v)
    of "!": (true, (if v == 0: 1'i64 else: 0'i64))
    else: (false, 0'i64)
  of nkBinary:
    let (okA, a) = evalConstInt(n.a)
    let (okB, b) = evalConstInt(n.b)
    if not okA or not okB: return (false, 0'i64)
    case n.op
    of "+": (true, a + b)
    of "-": (true, a - b)
    of "*": (true, a * b)
    of "/": (if b == 0: (false, 0'i64) else: (true, a div b))
    of "%": (if b == 0: (false, 0'i64) else: (true, a mod b))
    of "<<": (true, a shl b)
    of ">>": (true, a shr b)
    of "&": (true, a and b)
    of "|": (true, a or b)
    of "^": (true, a xor b)
    of "&&": (true, (if a != 0 and b != 0: 1'i64 else: 0'i64))
    of "||": (true, (if a != 0 or b != 0: 1'i64 else: 0'i64))
    of "==": (true, (if a == b: 1'i64 else: 0'i64))
    of "!=": (true, (if a != b: 1'i64 else: 0'i64))
    of "<": (true, (if a < b: 1'i64 else: 0'i64))
    of ">": (true, (if a > b: 1'i64 else: 0'i64))
    of "<=": (true, (if a <= b: 1'i64 else: 0'i64))
    of ">=": (true, (if a >= b: 1'i64 else: 0'i64))
    else: (false, 0'i64)
  of nkCond:
    let (okC, c) = evalConstInt(n.a)
    if not okC: return (false, 0'i64)
    evalConstInt(if c != 0: n.b else: n.c)
  of nkCast:
    evalConstInt(n.a)  # ignorujemy docelowy typ (obcięcie/rozszerzenie) - uproszczenie
  of nkSizeofType:
    (true, int64(typeSizeOf(n.typ)))
  of nkSizeofExpr:
    (false, 0'i64)  # wymagałoby wnioskowania typu wyrażenia - poza zakresem const-eval
  of nkComma:
    if n.list.len == 0: (false, 0'i64) else: evalConstInt(n.list[^1])
  else:
    (false, 0'i64)
