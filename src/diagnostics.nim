import std/strutils

type
  Severity* = enum sevError, sevWarning, sevNote

  Diagnostic* = object
    severity*: Severity
    file*: string
    line*, col*: int
    length*: int          ## ile znaków podkreślić (min. 1)
    message*: string
    suggestion*: string   ## "" jeśli brak sugestii naprawy
    notes*: seq[string]   ## dodatkowe linie kontekstu/wyjaśnienia

const
  AnsiReset = "\e[0m"
  AnsiBold = "\e[1m"
  AnsiRed = "\e[31m"
  AnsiYellow = "\e[33m"
  AnsiCyan = "\e[36m"
  AnsiGreen = "\e[32m"
  AnsiDim = "\e[2m"

proc severityLabel(s: Severity): string =
  case s
  of sevError: "error"
  of sevWarning: "warning"
  of sevNote: "note"

proc severityColor(s: Severity): string =
  case s
  of sevError: AnsiRed
  of sevWarning: AnsiYellow
  of sevNote: AnsiCyan

proc c(useColor: bool, code: string): string =
  if useColor: code else: ""

## Wydobywa konkretną linię tekstu źródłowego (1-indexed) bez wczytywania
## całego pliku po raz drugi przy każdym diagnostyku - w praktyce wołający
## powinien cache'ować to per plik; tu prosta, samodzielna implementacja.
proc sourceLineOf*(src: string, lineNo: int): string =
  var current = 1
  var start = 0
  var i = 0
  while i <= src.len:
    if current == lineNo:
      start = i
      break
    if i < src.len and src[i] == '\n':
      inc current
    inc i
  if current != lineNo:
    return ""
  var e = start
  while e < src.len and src[e] != '\n':
    inc e
  result = src[start ..< e]

proc report*(d: Diagnostic, useColor = true) =
  let loc = d.file & ":" & $d.line & ":" & $d.col
  let sevStr = c(useColor, AnsiBold) & c(useColor, severityColor(d.severity)) &
               severityLabel(d.severity) & c(useColor, AnsiReset)
  stderr.writeLine c(useColor, AnsiBold) & loc & ": " & c(useColor, AnsiReset) &
    sevStr & c(useColor, AnsiBold) & ": " & d.message & c(useColor, AnsiReset)

  if d.notes.len > 0 or true:
    discard # miejsce na ewentualny wydruk pliku źródłowego robi wołający,
            # bo tu nie trzymamy globalnego cache treści plików

proc reportWithSource*(d: Diagnostic, src: string, useColor = true) =
  report(d, useColor)
  let lineText = sourceLineOf(src, d.line)
  if lineText.len == 0:
    return
  let gutter = $d.line
  let pad = " ".repeat(gutter.len)
  stderr.writeLine c(useColor, AnsiDim) & pad & " |" & c(useColor, AnsiReset)
  stderr.writeLine gutter & " | " & lineText
  let caretPad = " ".repeat(max(0, d.col - 1))
  let underline = "^" & "~".repeat(max(0, d.length - 1))
  stderr.writeLine c(useColor, AnsiDim) & pad & " | " & c(useColor, AnsiReset) &
    c(useColor, AnsiBold) & c(useColor, severityColor(d.severity)) &
    caretPad & underline & c(useColor, AnsiReset)
  if d.suggestion.len > 0:
    stderr.writeLine c(useColor, AnsiDim) & pad & " = " & c(useColor, AnsiReset) &
      c(useColor, AnsiGreen) & "suggestion: " & c(useColor, AnsiReset) & d.suggestion
  for n in d.notes:
    stderr.writeLine c(useColor, AnsiDim) & pad & " = " & c(useColor, AnsiReset) &
      c(useColor, AnsiCyan) & "note: " & c(useColor, AnsiReset) & n

## Konstruktory pomocnicze - trzymają wywołania w lexerze/parserze krótkie.
proc errAt*(file: string, line, col: int, msg: string,
            length = 1, suggestion = ""): Diagnostic =
  Diagnostic(severity: sevError, file: file, line: line, col: col,
             length: length, message: msg, suggestion: suggestion, notes: @[])

proc warnAt*(file: string, line, col: int, msg: string,
             length = 1, suggestion = ""): Diagnostic =
  Diagnostic(severity: sevWarning, file: file, line: line, col: col,
             length: length, message: msg, suggestion: suggestion, notes: @[])
