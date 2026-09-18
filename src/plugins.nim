import std/[dynlib, os]
import lexer/tokens as lextok

const PluginAbiVersion* = 1

type
  CPluginToken* {.exportc: "ZccToken".} = object
    kind*: cint       ## odwzorowanie TokenKind (ordinal) - patrz tokenKindToC
    text*: cstring
    line*, col*: cint

  CPluginDiag* {.exportc: "ZccPluginDiag".} = object
    line*, col*: cint
    isError*: cint     ## 1 = error, 0 = warning
    message*: cstring
    suggestion*: cstring  ## może być pusty cstring

  ## Sygnatura funkcji eksportowanej przez plugin .so:
  ##   int zcc_plugin_abi_version(void);
  ##   int zcc_plugin_check_tokens(const ZccToken* toks, int count,
  ##                                ZccPluginDiag* out_diags, int max_diags);
  ## Zwraca liczbę wypełnionych diagnostyk (<= max_diags).
  CheckTokensProc = proc(toks: ptr UncheckedArray[CPluginToken], count: cint,
                          outDiags: ptr UncheckedArray[CPluginDiag],
                          maxDiags: cint): cint {.cdecl.}
  AbiVersionProc = proc(): cint {.cdecl.}

type LoadedPlugin* = object
  path*: string
  lib: LibHandle
  checkTokens: CheckTokensProc
  ok*: bool
  error*: string

proc tokenKindToC(k: lextok.TokenKind): cint = cint(ord(k))

proc loadPlugin*(path: string): LoadedPlugin =
  result = LoadedPlugin(path: path, ok: false, error: "")
  if not fileExists(path):
    result.error = "plik pluginu nie istnieje: " & path
    return
  let lib = loadLib(path)
  if lib == nil:
    result.error = "nie udało się załadować .so: " & path
    return
  result.lib = lib

  let abiSym = symAddr(lib, "zcc_plugin_abi_version")
  if abiSym == nil:
    result.error = path & ": brak symbolu zcc_plugin_abi_version"
    unloadLib(lib)
    return
  let abiFn = cast[AbiVersionProc](abiSym)
  let version = abiFn()
  if version != PluginAbiVersion:
    result.error = path & ": niekompatybilna wersja ABI (plugin=" & $version &
      ", zcc=" & $PluginAbiVersion & ")"
    unloadLib(lib)
    return

  let checkSym = symAddr(lib, "zcc_plugin_check_tokens")
  if checkSym == nil:
    result.error = path & ": brak symbolu zcc_plugin_check_tokens"
    unloadLib(lib)
    return
  result.checkTokens = cast[CheckTokensProc](checkSym)
  result.ok = true

const MaxDiagsPerPlugin = 256

## Uruchamia plugin na strumieniu tokenów jednej jednostki translacji.
## Zwraca listę (linia, kolumna, czyBłąd, wiadomość, sugestia) - warstwa
## main.nim/diagnostics.nim odpowiada za docelowy format wydruku.
proc runPluginOnTokens*(p: LoadedPlugin,
                         toks: seq[lextok.Token]): seq[tuple[line, col: int, isError: bool, message, suggestion: string]] =
  result = @[]
  if not p.ok: return
  var cToks = newSeq[CPluginToken](toks.len)
  for i, t in toks:
    cToks[i] = CPluginToken(kind: tokenKindToC(t.kind), text: t.text.cstring,
                             line: cint(t.line), col: cint(t.col))
  var outBuf = newSeq[CPluginDiag](MaxDiagsPerPlugin)
  let n = p.checkTokens(
    cast[ptr UncheckedArray[CPluginToken]](addr cToks[0]), cint(toks.len),
    cast[ptr UncheckedArray[CPluginDiag]](addr outBuf[0]), cint(MaxDiagsPerPlugin))
  for i in 0 ..< min(int(n), MaxDiagsPerPlugin):
    let d = outBuf[i]
    result.add (int(d.line), int(d.col), d.isError != 0, $d.message,
                (if d.suggestion != nil: $d.suggestion else: ""))

proc unload*(p: var LoadedPlugin) =
  if p.ok and p.lib != nil:
    unloadLib(p.lib)
    p.ok = false

proc loadAllPlugins*(paths: seq[string]): seq[LoadedPlugin] =
  result = @[]
  for path in paths:
    let p = loadPlugin(path)
    result.add p
    if not p.ok:
      stderr.writeLine "zcc: warning: plugin nie załadowany: " & p.error
