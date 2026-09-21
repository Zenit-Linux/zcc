import std/strutils

## AST + reprezentacja typów C dla zcc.
##
## Świadomie "płaski" projekt węzła (Node jako jeden ref object z ogólnymi
## polami a/b/c/list zamiast osobnego typu wariantowego per NodeKind) -
## spójne ze stylem reszty projektu (patrz options.nim/Config): mniej
## boilerplate'u dla kompilatora na tym etapie, kosztem tego że znaczenie
## pól trzeba czytać z komentarza przy każdym NodeKind poniżej. Jeśli AST
## urośnie (etap 5+, pełne C99-C23), do rozważenia przejście na `case`
## warianty dla bezpieczeństwa typów.

type
  StorageClass* = enum
    scNone, scTypedef, scExtern, scStatic, scAuto, scRegister

  TypeKind* = enum
    tkVoid, tkBool, tkChar, tkShort, tkInt, tkLong, tkLongLong,
    tkFloat, tkDouble, tkLongDouble,
    tkPointer, tkArray, tkFunction, tkStruct, tkUnion, tkEnum,
    tkTypedefName,
    tkError   ## typ-placeholder po błędzie parsowania/sema - tłumi kaskadę

  Field* = object
    name*: string
    typ*: CType
    bitWidth*: Node     ## nil jeśli pole nie jest bitfieldem
    line*, col*: int

  Enumerator* = object
    name*: string
    value*: Node        ## nil = wartość automatyczna (poprzednia + 1)
    line*, col*: int

  CType* = ref object
    kind*: TypeKind
    isUnsigned*: bool        ## tkChar..tkLongLong
    isConst*, isVolatile*: bool
    tag*: string              ## tkStruct/tkUnion/tkEnum: nazwa tagu ("" = anonimowy)
                                ## tkTypedefName: nazwa aliasu
    pointee*: CType             ## tkPointer
    elem*: CType                  ## tkArray: typ elementu
    arrayLen*: Node                 ## tkArray: wyrażenie rozmiaru, nil = [] (niepełny typ)
    returnType*: CType                ## tkFunction
    paramTypes*: seq[CType]             ## tkFunction: typy parametrów (nazwy - patrz Node.params)
    isVariadic*: bool                    ## tkFunction: ... na końcu listy parametrów
    hasKnownParams*: bool                 ## false dla starego stylu K&R `f()` (nieznana lista)
    fields*: seq[Field]                    ## tkStruct/tkUnion
    isComplete*: bool                       ## tkStruct/tkUnion/tkEnum: czy ciało zostało podane
    enumerators*: seq[Enumerator]             ## tkEnum
    resolved*: CType                          ## tkTypedefName: typ docelowy (wypełnia sema)

  NodeKind* = enum
    # --- literały i identyfikatory ---
    nkIntLit, nkFloatLit, nkCharLit, nkStringLit, nkIdent,
    # --- wyrażenia ---
    nkBinary,       ## op = operator, a = lewy, b = prawy
    nkAssign,       ## op = operator ("=", "+=", ...), a = lhs, b = rhs
    nkUnaryPre,     ## op = operator prefiksowy, a = operand
    nkUnaryPost,    ## op = operator postfiksowy ("++"/"--"), a = operand
    nkCond,         ## a = warunek, b = then, c = else  (?:)
    nkCall,         ## a = wywoływane wyrażenie, list = argumenty
    nkIndex,        ## a = tablica/wskaźnik, b = indeks
    nkMember,       ## a = obiekt, strVal = nazwa pola  (.)
    nkArrow,        ## a = wskaźnik, strVal = nazwa pola (->)
    nkCast,         ## typ = typ docelowy, a = wyrażenie
    nkSizeofExpr,   ## a = wyrażenie
    nkSizeofType,   ## typ = typ
    nkComma,        ## list = wyrażenia (wynik = ostatnie)
    nkInitList,     ## list = elementy inicjalizatora (mogą być zagnieżdżone nkInitList)
    # --- instrukcje ---
    nkCompound,     ## list = instrukcje bloku
    nkExprStmt,     ## a = wyrażenie (nil dla samego ';')
    nkIf,           ## a = warunek, b = then, c = else (może być nil)
    nkWhile,        ## a = warunek, b = ciało
    nkDoWhile,      ## a = warunek, b = ciało
    nkFor,          ## a = init (nkDeclStmt/nkExprStmt/nil), b = warunek (nil=zawsze prawda),
                     ## c = wyrażenie post-iteracji (nil), d = ciało
    nkReturnStmt,   ## a = wyrażenie (nil dla `return;`)
    nkBreakStmt, nkContinueStmt,
    nkGotoStmt,     ## strVal = nazwa etykiety
    nkLabelStmt,    ## strVal = nazwa etykiety, a = instrukcja etykietowana
    nkSwitchStmt,   ## a = wyrażenie, b = ciało
    nkCaseStmt,     ## a = wyrażenie stałe, b = instrukcja
    nkDefaultStmt,  ## a = instrukcja
    nkEmptyStmt,
    nkDeclStmt,     ## list = lokalne deklaracje (nkVarDecl/nkTypedefDecl/nkTagDecl)
    # --- deklaracje / top-level ---
    nkVarDecl,      ## strVal=nazwa, typ=CType, a=inicjalizator (może być nil / nkInitList)
    nkFuncDecl,      ## strVal=nazwa, typ=CType(tkFunction), params = nkVarDecl (parametry)
    nkFuncDef,       ## jak nkFuncDecl + b = ciało (nkCompound)
    nkTypedefDecl,    ## strVal=nazwa aliasu, typ=typ docelowy
    nkTagDecl,         ## samodzielna deklaracja struct/union/enum (bez zmiennej), typ=CType
    nkStaticAssert,     ## a = wyrażenie warunku, strVal = komunikat (może być "")
    nkTranslationUnit    ## list = deklaracje top-level

  Node* = ref object
    kind*: NodeKind
    line*, col*: int
    strVal*: string        ## tekst literału / nazwa identyfikatora/etykiety/pola
    op*: string              ## operator (nkBinary/nkAssign/nkUnaryPre/nkUnaryPost)
    a*, b*, c*, d*: Node       ## dzieci ogólnego przeznaczenia - znaczenie wg komentarza przy NodeKind
    list*: seq[Node]            ## lista dzieci zmiennej długości
    typ*: CType                   ## typ jawny (deklaracje/cast/sizeof(type));
                                    ## dla wyrażeń wypełniane przez sema (inferType)
    storage*: StorageClass
    isInline*: bool
    isNoreturn*: bool
    params*: seq[Node]              ## nkFuncDecl/nkFuncDef: parametry jako nkVarDecl

# --- konstruktory pomocnicze CType dla typów bazowych (używane w wielu miejscach) ---

proc ctype*(kind: TypeKind, unsigned = false): CType =
  CType(kind: kind, isUnsigned: unsigned, isComplete: true, hasKnownParams: true)

proc tyVoidC*(): CType = ctype(tkVoid)
proc tyIntC*(): CType = ctype(tkInt)
proc tyErrorC*(): CType = ctype(tkError)

proc pointerTo*(t: CType): CType =
  CType(kind: tkPointer, pointee: t, isComplete: true, hasKnownParams: true)

## Odwraca CType do czytelnej postaci tekstowej (do --dump-ast, diagnostyk sema).
## Nieidealna reprodukcja składni C (np. deklaratory tablic/funkcji w C
## czyta się "na spirali", nie liniowo) - wystarczająca do debugowania.
proc typeToString*(t: CType): string =
  if t.isNil: return "<?>"
  var quals = ""
  if t.isConst: quals.add "const "
  if t.isVolatile: quals.add "volatile "
  case t.kind
  of tkVoid: result = quals & "void"
  of tkBool: result = quals & "_Bool"
  of tkChar: result = quals & (if t.isUnsigned: "unsigned char" else: "char")
  of tkShort: result = quals & (if t.isUnsigned: "unsigned short" else: "short")
  of tkInt: result = quals & (if t.isUnsigned: "unsigned int" else: "int")
  of tkLong: result = quals & (if t.isUnsigned: "unsigned long" else: "long")
  of tkLongLong: result = quals & (if t.isUnsigned: "unsigned long long" else: "long long")
  of tkFloat: result = quals & "float"
  of tkDouble: result = quals & "double"
  of tkLongDouble: result = quals & "long double"
  of tkPointer: result = typeToString(t.pointee) & " *" & quals.strip()
  of tkArray:
    result = typeToString(t.elem) & "[" & (if t.arrayLen.isNil: "" else: "N") & "]"
  of tkFunction:
    var ps: seq[string] = @[]
    for p in t.paramTypes: ps.add typeToString(p)
    if t.isVariadic: ps.add "..."
    if ps.len == 0 and t.hasKnownParams: ps.add "void"
    result = typeToString(t.returnType) & " (" & ps.join(", ") & ")"
  of tkStruct: result = quals & "struct " & (if t.tag.len > 0: t.tag else: "<anon>")
  of tkUnion: result = quals & "union " & (if t.tag.len > 0: t.tag else: "<anon>")
  of tkEnum: result = quals & "enum " & (if t.tag.len > 0: t.tag else: "<anon>")
  of tkTypedefName: result = quals & t.tag
  of tkError: result = "<error-type>"
