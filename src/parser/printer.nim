import std/strutils
import ast

proc storageStr(s: StorageClass): string =
  case s
  of scNone: ""
  of scTypedef: "typedef "
  of scExtern: "extern "
  of scStatic: "static "
  of scAuto: "auto "
  of scRegister: "register "

proc indentStr(n: int): string = "  ".repeat(n)

proc dumpNode(n: Node, indent: int, res: var string) =
  if n.isNil:
    res.add indentStr(indent) & "<nil>\n"
    return
  let loc = "(" & $n.line & ":" & $n.col & ")"
  case n.kind
  of nkIntLit, nkFloatLit, nkCharLit, nkStringLit:
    res.add indentStr(indent) & $n.kind & " " & n.strVal & " " & loc & "\n"
  of nkIdent:
    res.add indentStr(indent) & "Ident " & n.strVal & " " & loc & "\n"
  of nkBinary, nkAssign:
    res.add indentStr(indent) & $n.kind & " '" & n.op & "' " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
  of nkUnaryPre, nkUnaryPost:
    res.add indentStr(indent) & $n.kind & " '" & n.op & "' " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkCond:
    res.add indentStr(indent) & "Cond " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
    dumpNode(n.c, indent + 1, res)
  of nkCall:
    res.add indentStr(indent) & "Call " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    for arg in n.list: dumpNode(arg, indent + 1, res)
  of nkIndex:
    res.add indentStr(indent) & "Index " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
  of nkMember:
    res.add indentStr(indent) & "Member ." & n.strVal & " " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkArrow:
    res.add indentStr(indent) & "Arrow ->" & n.strVal & " " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkCast:
    res.add indentStr(indent) & "Cast (" & typeToString(n.typ) & ") " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkSizeofExpr:
    res.add indentStr(indent) & "SizeofExpr " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkSizeofType:
    res.add indentStr(indent) & "SizeofType " & typeToString(n.typ) & " " & loc & "\n"
  of nkComma:
    res.add indentStr(indent) & "Comma " & loc & "\n"
    for e in n.list: dumpNode(e, indent + 1, res)
  of nkInitList:
    res.add indentStr(indent) & "InitList " & loc & "\n"
    for e in n.list: dumpNode(e, indent + 1, res)
  of nkCompound:
    res.add indentStr(indent) & "Compound " & loc & "\n"
    for s in n.list: dumpNode(s, indent + 1, res)
  of nkExprStmt:
    res.add indentStr(indent) & "ExprStmt " & loc & "\n"
    if not n.a.isNil: dumpNode(n.a, indent + 1, res)
  of nkIf:
    res.add indentStr(indent) & "If " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
    if not n.c.isNil: dumpNode(n.c, indent + 1, res)
  of nkWhile:
    res.add indentStr(indent) & "While " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
  of nkDoWhile:
    res.add indentStr(indent) & "DoWhile " & loc & "\n"
    dumpNode(n.b, indent + 1, res)
    dumpNode(n.a, indent + 1, res)
  of nkFor:
    res.add indentStr(indent) & "For " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
    dumpNode(n.c, indent + 1, res)
    dumpNode(n.d, indent + 1, res)
  of nkReturnStmt:
    res.add indentStr(indent) & "Return " & loc & "\n"
    if not n.a.isNil: dumpNode(n.a, indent + 1, res)
  of nkBreakStmt: res.add indentStr(indent) & "Break " & loc & "\n"
  of nkContinueStmt: res.add indentStr(indent) & "Continue " & loc & "\n"
  of nkGotoStmt: res.add indentStr(indent) & "Goto " & n.strVal & " " & loc & "\n"
  of nkLabelStmt:
    res.add indentStr(indent) & "Label " & n.strVal & " " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkSwitchStmt:
    res.add indentStr(indent) & "Switch " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
  of nkCaseStmt:
    res.add indentStr(indent) & "Case " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
    dumpNode(n.b, indent + 1, res)
  of nkDefaultStmt:
    res.add indentStr(indent) & "Default " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkEmptyStmt: res.add indentStr(indent) & "EmptyStmt " & loc & "\n"
  of nkDeclStmt:
    res.add indentStr(indent) & "DeclStmt " & loc & "\n"
    for d in n.list: dumpNode(d, indent + 1, res)
  of nkVarDecl:
    res.add indentStr(indent) & "VarDecl " & storageStr(n.storage) & n.strVal &
      " : " & typeToString(n.typ) & " " & loc & "\n"
    if not n.a.isNil: dumpNode(n.a, indent + 1, res)
  of nkFuncDecl, nkFuncDef:
    res.add indentStr(indent) & $n.kind & " " & storageStr(n.storage) &
      (if n.isInline: "inline " else: "") & n.strVal & " : " & typeToString(n.typ) &
      " " & loc & "\n"
    for prm in n.params: dumpNode(prm, indent + 1, res)
    if n.kind == nkFuncDef: dumpNode(n.b, indent + 1, res)
  of nkTypedefDecl:
    res.add indentStr(indent) & "Typedef " & n.strVal & " = " & typeToString(n.typ) &
      " " & loc & "\n"
  of nkTagDecl:
    res.add indentStr(indent) & "TagDecl " & typeToString(n.typ) & " " & loc & "\n"
    if not n.typ.isNil:
      for f in n.typ.fields:
        res.add indentStr(indent + 1) & "Field " & f.name & " : " & typeToString(f.typ) & "\n"
      for e in n.typ.enumerators:
        res.add indentStr(indent + 1) & "Enumerator " & e.name & "\n"
  of nkStaticAssert:
    res.add indentStr(indent) & "StaticAssert " & loc & "\n"
    dumpNode(n.a, indent + 1, res)
  of nkTranslationUnit:
    res.add indentStr(indent) & "TranslationUnit\n"
    for d in n.list: dumpNode(d, indent + 1, res)

proc dumpAst*(n: Node): string =
  result = ""
  dumpNode(n, 0, result)
