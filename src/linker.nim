import std/[strutils, tables, osproc, sequtils]
import target

type LinkerSuggestion* = object
  missingSymbol*: string
  suggestedFlag*: string
  reason*: string

## Tablica znanych symboli -> biblioteka. Celowo mała i skoncentrowana na
## najczęstszych, realnych przypadkach ("zapomniałem -lpthread/-lm") -
## rozbudowa na podstawie faktycznych zgłoszeń, nie próba wyczerpania
## całej przestrzeni symboli libc/libstdc++.
const KnownSymbolLibs = {
  "pthread_create": ("pthread", "funkcje wątków POSIX wymagają linkowania z pthread"),
  "pthread_mutex_lock": ("pthread", "funkcje wątków POSIX wymagają linkowania z pthread"),
  "sin": ("m", "funkcje matematyczne (libm) nie są linkowane domyślnie na części systemów"),
  "cos": ("m", "funkcje matematyczne (libm) nie są linkowane domyślnie na części systemów"),
  "sqrt": ("m", "funkcje matematyczne (libm) nie są linkowane domyślnie na części systemów"),
  "pow": ("m", "funkcje matematyczne (libm) nie są linkowane domyślnie na części systemów"),
  "dlopen": ("dl", "dynamiczne ładowanie bibliotek wymaga libdl (na glibc; musl ma to w libc)"),
  "clock_gettime": ("rt", "na starszym glibc clock_gettime jest w librt, nie libc"),
  "shm_open": ("rt", "shared memory POSIX jest w librt na starszym glibc"),
}.toTable

## Rozpoznaje linie "undefined reference to `NAZWA'" (GNU ld) oraz
## "undefined symbol: NAZWA" (LLD/LLVM). Celowo bez std/re (dociąga
## libpcre jako zależność systemową przy linkowaniu, czego wolimy
## uniknąć w samym kompilatorze dystrybucji) - proste parsowanie
## wystarcza dla tych dwóch stałych formatów.
proc parseUndefinedSymbols*(linkerOutput: string): seq[string] =
  result = @[]
  const gnuMarker = "undefined reference to `"
  const lldMarker = "undefined symbol:"
  for line in linkerOutput.splitLines():
    let gi = line.find(gnuMarker)
    if gi >= 0:
      let rest = line[gi + gnuMarker.len .. ^1]
      let e = rest.find('\'')
      if e > 0:
        result.add rest[0 ..< e]
      continue
    let li = line.find(lldMarker)
    if li >= 0:
      let rest = line[li + lldMarker.len .. ^1].strip()
      var sym = ""
      for c in rest:
        if c in {' ', '\t', ','}: break
        sym.add c
      if sym.len > 0:
        result.add sym

proc suggestFor*(symbol: string): LinkerSuggestion =
  # symbole C++ bywają mangled (_ZN...) - zdejmij ewentualny C-linkage
  # prefix i spróbuj dopasować surowe C nazwy; pełny demangling C++ to
  # osobny temat (TODO, potrzebny dopiero gdy zcc wspiera C++).
  let clean = symbol.strip(chars = {'_'})
  if KnownSymbolLibs.hasKey(symbol):
    let (lib, reason) = KnownSymbolLibs[symbol]
    return LinkerSuggestion(missingSymbol: symbol, suggestedFlag: "-l" & lib, reason: reason)
  if KnownSymbolLibs.hasKey(clean):
    let (lib, reason) = KnownSymbolLibs[clean]
    return LinkerSuggestion(missingSymbol: symbol, suggestedFlag: "-l" & lib, reason: reason)
  LinkerSuggestion(missingSymbol: symbol, suggestedFlag: "", reason: "")

proc analyzeLinkerFailure*(linkerOutput: string): seq[LinkerSuggestion] =
  result = @[]
  var seen: seq[string] = @[]
  for sym in parseUndefinedSymbols(linkerOutput):
    if sym in seen: continue
    seen.add sym
    let sug = suggestFor(sym)
    if sug.suggestedFlag.len > 0:
      result.add sug

proc formatSuggestions*(suggestions: seq[LinkerSuggestion]): string =
  if suggestions.len == 0: return ""
  var lines: seq[string] = @[]
  lines.add "zcc: możliwe naprawy błędu linkowania:"
  for s in suggestions:
    lines.add "  brakujący symbol '" & s.missingSymbol & "' -> spróbuj dodać " &
      s.suggestedFlag & "  (" & s.reason & ")"
  lines.join("\n")

# ============================== rzeczywiste wywołania as/ld ==============================
#
# Świadomie `as`/`ld` z binutils, NIE `gcc`/`clang` jako "linker driver" -
# zcc ma być samodzielnym kompilatorem, nie nakładką na cudzy driver.
# Koszt tej decyzji: musimy sami znaleźć obiekty startowe (crt1.o itd.)
# i katalog libc - patrz `target.findCLibPaths`.

## Składa jeden plik .s (wygenerowany przez codegen.nim) do obiektu .o.
proc assembleFile*(asmPath, objPath: string): tuple[ok: bool, output: string] =
  let (output, code) = execCmdEx("as --64 -o " & quoteShell(objPath) & " " & quoteShell(asmPath))
  (code == 0, output)

## Linkuje gotowe pliki .o w wykonywalny plik ELF, dowiązując crt*.o i
## libc dla danej architektury/ABI (statycznie domyślnie - patrz README
## "statyczne linkowanie domyślnie"). Zwraca (false, <surowy wyjście ld>)
## przy błędzie - wołający może przepuścić to przez
## `analyzeLinkerFailure`/`formatSuggestions` z tego samego modułu, żeby
## dodać sugestie brakujących bibliotek.
proc linkExecutable*(objFiles: seq[string], output: string, tgt: Target,
                      staticLink: bool, extraLibs: seq[string] = @[],
                      extraLibDirs: seq[string] = @[]): tuple[ok: bool, output: string] =
  let libc = findCLibPaths(tgt.abi)
  if not libc.found:
    return (false, "zcc: nie znaleziono crt1.o/crti.o/crtn.o ani biblioteki libc " &
      "dla ABI '" & $tgt.abi & "' (ani dla alternatywnej dostępnej na hoście) - " &
      "zainstaluj pakiet nagłówków/bibliotek developerskich libc (np. libc6-dev " &
      "dla glibc albo musl-tools dla musl)")
  var args: seq[string] = @["-o", output]
  if staticLink:
    args.add "-static"
  else:
    args.add "-dynamic-linker"
    args.add libc.dynLinker
  args.add libc.crt1
  args.add libc.crti
  for f in objFiles: args.add f
  args.add "-L" & libc.libDir
  for d in extraLibDirs: args.add "-L" & d
  args.add "--start-group"
  args.add "-lc"
  for l in extraLibs: args.add "-l" & l
  if staticLink and libc.abi == tabiGnu:
    # glibc.a odwołuje się do symboli wsparcia z libgcc.a/libgcc_eh.a
    # nawet w programach, które same ich nie używają - patrz komentarz
    # przy `findLibgcc`/`findLibgccEh` w target.nim.
    let libgcc = findLibgcc()
    let libgccEh = findLibgccEh()
    if libgcc.len > 0: args.add libgcc
    if libgccEh.len > 0: args.add libgccEh
  args.add "--end-group"
  args.add libc.crtn
  let cmd = "ld " & args.mapIt(quoteShell(it)).join(" ")
  let (output, code) = execCmdEx(cmd)
  (code == 0, output)
