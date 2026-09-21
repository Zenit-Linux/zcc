import std/[os, strutils, sets, hashes]
import options as zccopts
import lexer/[lexer, tokens]
import diagnostics
import target
import hardening
import depgen
import cache
import parallel
import preprocessor/preprocessor as pp
import sanitize
import lto
import reproducible
import projectconfig
import plugins
import parser/[parser, printer]
import sema/sema
import codegen/codegen
import linker

const Version = "0.0.1-dev"

proc printHelp() =
  echo """
zcc """ & Version & """ - Zenit C Compiler (C99-C23), napisany w Nim

Użycie: zcc [opcje] plik.c [plik2.c ...]

Podstawowe:
  -o <plik>         Plik wyjściowy
  -c                Tylko kompiluj do .o, nie linkuj
  -S                Zatrzymaj się na asemblerze
  -E                Tylko preprocesor (wypisz rozwinięty kod na stdout)
  -std=c99|c11|c17|c23   Standard C (domyślnie c17)
  -O0|-O1|-O2|-O3|-Os     Poziom optymalizacji (domyślnie -O0)
  -g                Informacje debugowe
  -I <dir>          Katalog nagłówków
  -D <name>=<val>   Definicja makra
  -L <dir>          Katalog bibliotek
  -l <name>         Linkowana biblioteka
  -Werror           Traktuj ostrzeżenia jak błędy
  -v, --verbose     Tryb gadatliwy
  --no-color        Wyłącz kolory w diagnostyce

Linkowanie:
  -static           Wymuś statyczne linkowanie (domyślne i tak)
  -dynamic          Linkuj dynamicznie (alias: --dyn-link)

Hardening (bezpieczeństwo domyślnie włączone, agresywniej niż gcc):
  --hardened=off|default|max   (domyślnie: default)
  --no-hardened                 alias dla --hardened=off

Sanitizery (dev/CI - narzut wydajnościowy, nie do produkcji):
  -fsanitize=address,undefined,thread,memory   (rozdzielone przecinkami)

LTO:
  --lto=off|thin|full   (domyślnie: off; zalecane: thin przy -O2/-O3)

Reprodukowalne buildy:
  --reproducible     Normalizacja ścieżek/timestampów (reproducible-builds.org)

Cross-compilation:
  --target=<triple>  np. aarch64-linux-musl, x86_64-linux-gnu
                      (domyślnie: host, ABI musl)

Tooling / wydajność builda:
  -MM               Wypisz reguły zależności (make) na stdout, nie kompiluj
  -MMD              Generuj plik .d obok wyjścia i kompiluj normalnie
  -j <N>, --jobs=<N>   Liczba równoległych jednostek translacji
  --no-cache         Wyłącz cache obiektów (domyślnie włączony)
  --cache-dir=<dir>  Katalog cache (domyślnie ~/.cache/zcc)
  --cache-stats      Pokaż statystyki cache i zakończ
  --cache-clear      Wyczyść cache i zakończ
  --no-pch           Wyłącz prekompilowane nagłówki

Pluginy:
  --plugin=<ścieżka.so>   Załaduj plugin lintujący (ABI: patrz src/plugins.nim)

Konfiguracja projektu:
  Automatycznie wczytywana z zcc.toml (najbliższego w górę drzewa
  katalogów) jako domyślne wartości - flagi CLI mają pierwszeństwo.

Front-end (parser/sema - etap 2 z ROADMAP.md):
  -fsyntax-only      Tylko sparsuj i sprawdź semantycznie, nie generuj kodu
  --dump-ast         [debug] wypisz drzewo AST (po parsowaniu) i zakończ
  --no-sema          z -fsyntax-only/--dump-ast: pomiń analizę semantyczną

Debug:
  --dump-tokens      [debug] wypisz strumień tokenów (po preprocesorze) i zakończ
  --no-preprocess    [debug] z --dump-tokens/--dump-ast: pomiń preprocesor, lexuj surowy plik
  --version          Wersja
  --help             Ta pomoc
"""

## Rozdziela `-std=c17` na ("std", "c17"); brak '=' -> (całość, "").
proc splitEq(s: string): (string, string) =
  let i = s.find('=')
  if i >= 0: (s[0 ..< i], s[i+1 .. ^1])
  else: (s, "")

## Usuwa duplikaty diagnostyk (ten sam plik:linia:kolumna:treść) - parser
## i sema celowo powtarzają niektóre kontrole (np. break/continue poza
## pętlą) dla odporności, gdy używane są niezależnie od siebie (patrz
## komentarz w sema.nim), ale w normalnym pipeline'ie -fsyntax-only/
## --dump-ast oba przebiegi działają razem i bez deduplikacji użytkownik
## widziałby ten sam błąd dwa razy.
proc dedupDiags(diags: seq[Diagnostic]): seq[Diagnostic] =
  var seen = initHashSet[string]()
  result = @[]
  for d in diags:
    let key = $d.line & ":" & $d.col & ":" & d.message
    if key notin seen:
      seen.incl key
      result.add d

proc parseArgs(): zccopts.Config =
  # Baza: zcc.toml (jeśli istnieje) nadpisywane przez flagi CLI poniżej.
  #
  # UWAGA: celowo NIE używamy tu std/parseopt. `initOptParser` w Nim
  # traktuje każdą jednoznakową flagę z doklejoną wartością bez spacji
  # (styl gcc: `-std=c17`, `-Ipath`, `-Dfoo=1`, `-O2`) jako klaster
  # osobnych krótkich opcji ("-s","-t","-d",...) zamiast jednej flagi
  # z wartością - to cicho psuje właśnie ten podzbiór CLI zgodny z gcc,
  # który jest fundamentem integracji z kompilatorem Nim (patrz README
  # "Zgodność CLI z gcc" i ARCHITECTURE.md §1, Faza A). Stąd własny,
  # mały skaner argv świadomy tej niejednoznaczności.
  result = projectconfig.loadProjectConfig(getCurrentDir())
  var dumpTokens = false
  var noPreprocess = false
  var dumpAstFlag = false
  var syntaxOnly = false
  var noSema = false
  var cacheStats = false
  var cacheClear = false

  let rawArgs = commandLineParams()
  var i = 0

  ## Wartość dla flagi jednoliterowej: doklejona bezpośrednio do tokenu
  ## (`-Ifoo`) albo w kolejnym tokenie (`-I foo`) - obie formy są
  ## standardowe w gcc dla -I/-D/-L/-l/-o.
  proc attachedOrNext(rawArgs: seq[string], i: var int): string =
    let a = rawArgs[i]
    if a.len > 2:
      result = a[2 .. ^1]
    else:
      inc i
      if i < rawArgs.len: result = rawArgs[i]
      else:
        stderr.writeLine "zcc: brak wartości dla opcji '" & a & "'"
        quit(1)

  while i < rawArgs.len:
    let a = rawArgs[i]
    if a.len == 0 or a[0] != '-' or a == "-":
      result.inputs.add a
      inc i
      continue

    if a.len >= 2 and a[1] == '-':
      # --dluga-opcja  albo  --dluga-opcja=wartosc
      let (key, val) = splitEq(a[2 .. ^1])
      case key
      of "output": result.output = val
      of "shared": result.outKind = okSharedLib
      of "static": result.link = lmStatic
      of "dynamic", "dyn-link": result.link = lmDynamic
      of "verbose": result.verbose = true
      of "no-color": result.noColor = true
      of "dump-tokens": dumpTokens = true
      of "no-preprocess": noPreprocess = true
      of "dump-ast": dumpAstFlag = true
      of "fsyntax-only": syntaxOnly = true
      of "no-sema": noSema = true
      of "jobs":
        try: result.jobs = parseInt(val)
        except ValueError:
          stderr.writeLine "zcc: nieprawidłowa wartość --jobs: " & val
          quit(1)
      of "no-cache": result.cacheEnabled = false
      of "cache-dir": result.cacheDir = val
      of "cache-stats": cacheStats = true
      of "cache-clear": cacheClear = true
      of "no-pch": result.usePch = false
      of "target": result.targetTriple = val
      of "no-hardened": result.hardening = hardOff
      of "hardened":
        case val
        of "off": result.hardening = hardOff
        of "default", "": result.hardening = hardDefault
        of "max": result.hardening = hardMax
        else:
          stderr.writeLine "zcc: nieznany poziom hardeningu: " & val
          quit(1)
      of "lto": result.ltoMode = (if val.len > 0: val else: "thin")
      of "reproducible": result.reproducible = true
      of "plugin": result.pluginPaths.add val
      of "version":
        echo "zcc ", Version
        quit(0)
      of "help":
        printHelp()
        quit(0)
      else:
        stderr.writeLine "zcc: nieznana opcja: --" & key
      inc i
      continue

    # opcja jednoznakowa w stylu gcc, ewentualnie z doklejoną wartością
    let rest = a[1 .. ^1]
    if rest == "c": result.outKind = okObjectOnly; inc i
    elif rest == "S": result.outKind = okAssemblyOnly; inc i
    elif rest == "E": result.outKind = okPreprocessOnly; inc i
    elif rest == "g": result.debugInfo = true; inc i
    elif rest == "v": result.verbose = true; inc i
    elif rest == "shared": result.outKind = okSharedLib; inc i
    elif rest == "static": result.link = lmStatic; inc i
    elif rest == "dynamic": result.link = lmDynamic; inc i
    elif rest == "Werror": result.warningsAsErrors = true; inc i
    elif rest == "MM": result.depMode = depMM; inc i
    elif rest == "MMD": result.depMode = depMMD; inc i
    elif rest == "fsyntax-only": syntaxOnly = true; inc i
    elif rest.startsWith("std="):
      let val = rest[4 .. ^1]
      case val
      of "c99": result.std = stdC99
      of "c11": result.std = stdC11
      of "c17", "c18": result.std = stdC17
      of "c23": result.std = stdC23
      else:
        stderr.writeLine "zcc: nieznany standard: " & val
        quit(1)
      inc i
    elif rest.startsWith("fsanitize="):
      result.sanitizers = rest[10 .. ^1].split(',')
      inc i
    elif rest.len >= 1 and rest[0] == 'O':
      let lvl = rest[1 .. ^1]
      case lvl
      of "0": result.opt = opt0
      of "1": result.opt = opt1
      of "2": result.opt = opt2
      of "3": result.opt = opt3
      of "s": result.opt = optS
      else:
        stderr.writeLine "zcc: nieznany poziom optymalizacji: -" & rest
        quit(1)
      inc i
    elif rest.len >= 1 and rest[0] == 'I':
      let v = attachedOrNext(rawArgs, i)
      result.includeDirs.add v
      inc i
    elif rest.len >= 1 and rest[0] == 'L':
      let v = attachedOrNext(rawArgs, i)
      result.libDirs.add v
      inc i
    elif rest.len >= 1 and rest[0] == 'l':
      let v = attachedOrNext(rawArgs, i)
      result.libs.add v
      inc i
    elif rest.len >= 1 and rest[0] == 'D':
      let v = attachedOrNext(rawArgs, i)
      let parts = v.split('=', 1)
      if parts.len == 2: result.defines.add (parts[0], parts[1])
      else: result.defines.add (v, "1")
      inc i
    elif rest.len >= 1 and rest[0] == 'o':
      result.output = attachedOrNext(rawArgs, i)
      inc i
    elif rest.len >= 1 and rest[0] == 'j':
      let v = attachedOrNext(rawArgs, i)
      try: result.jobs = parseInt(v)
      except ValueError:
        stderr.writeLine "zcc: nieprawidłowa wartość -j: " & v
        quit(1)
      inc i
    else:
      stderr.writeLine "zcc: nieznana opcja: -" & rest
      inc i

  if cacheStats:
    let s = cache.stats(result)
    echo "zcc cache: ", s.entries, " obiektów, ", s.bytes, " B w ", cache.cacheDirFor(result)
    quit(0)
  if cacheClear:
    cache.clear(result)
    echo "zcc cache: wyczyszczony (", cache.cacheDirFor(result), ")"
    quit(0)

  if result.outKind == okPreprocessOnly:
    for f in result.inputs:
      try:
        stdout.write pp.preprocessFile(f, result.std, result.includeDirs)
      except pp.PreprocessError as e:
        stderr.writeLine "zcc: " & e.msg
        quit(1)
    quit(0)

  if dumpTokens:
    for f in result.inputs:
      var src: string
      if noPreprocess:
        src = readFile(f)
      else:
        try:
          src = pp.preprocessFile(f, result.std, result.includeDirs)
        except pp.PreprocessError as e:
          stderr.writeLine "zcc: " & e.msg
          quit(1)
      var lx = newLexer(src, f, result.std)
      var allToks: seq[Token] = @[]
      for tok in lx.tokens():
        allToks.add tok
        echo f, ":", tok.line, ":", tok.col, "\t", tok.kind, "\t", tok.text
      for d in lx.diags:
        reportWithSource(d, src, not result.noColor)

      if result.pluginPaths.len > 0:
        let loaded = loadAllPlugins(result.pluginPaths)
        for pl in loaded:
          if not pl.ok: continue
          let diags = runPluginOnTokens(pl, allToks)
          for d in diags:
            let sev = if d.isError: "error" else: "warning"
            stderr.writeLine f & ":" & $d.line & ":" & $d.col & ": " & sev &
              " [" & pl.path.extractFilename & "]: " & d.message &
              (if d.suggestion.len > 0: "\n  suggestion: " & d.suggestion else: "")
    quit(0)

  if dumpAstFlag or syntaxOnly:
    var hadErrors = false
    for f in result.inputs:
      var src: string
      if noPreprocess:
        src = readFile(f)
      else:
        try:
          src = pp.preprocessFile(f, result.std, result.includeDirs)
        except pp.PreprocessError as e:
          stderr.writeLine "zcc: " & e.msg
          quit(1)
      var lx = newLexer(src, f, result.std)
      var toks: seq[Token] = @[]
      for tok in lx.tokens(): toks.add tok
      for d in lx.diags:
        reportWithSource(d, src, not result.noColor)
        if d.severity == sevError: hadErrors = true

      let (unit, parseDiagsRaw) = parseTokens(toks, f, result.std)
      var allDiags = parseDiagsRaw
      if not noSema:
        allDiags.add runSema(unit, f)
      for d in dedupDiags(allDiags):
        reportWithSource(d, src, not result.noColor)
        if d.severity == sevError: hadErrors = true

      if dumpAstFlag:
        stdout.write printer.dumpAst(unit)
    quit(if hadErrors: 1 else: 0)

## Kompiluje jeden plik .c do obiektu ELF (.o): preprocesor -> lexer ->
## parser -> sema -> codegen (src/codegen/) -> `as`. Zwraca ścieżkę do
## powstałego .o (w katalogu tymczasowym, chyba że `finalObjPath` podano
## jawnie - używane przez tryb -c z jawnym `-o`) i czy się powiodło.
## Diagnostyki są od razu wypisywane (spójnie ze stylem -fsyntax-only).
proc compileToObject(f: string, cfg: zccopts.Config, tmpDir: string,
                      finalObjPath = ""): tuple[objPath: string, ok: bool] =
  var src: string
  try:
    src = pp.preprocessFile(f, cfg.std, cfg.includeDirs)
  except pp.PreprocessError as e:
    stderr.writeLine "zcc: " & e.msg
    return ("", false)

  var lx = newLexer(src, f, cfg.std)
  var toks: seq[Token] = @[]
  for tok in lx.tokens(): toks.add tok
  var hadErrors = false
  for d in lx.diags:
    reportWithSource(d, src, not cfg.noColor)
    if d.severity == sevError: hadErrors = true

  let (unit, parseDiags) = parseTokens(toks, f, cfg.std)
  var allDiags = parseDiags
  allDiags.add runSema(unit, f)
  for d in dedupDiags(allDiags):
    reportWithSource(d, src, not cfg.noColor)
    if d.severity == sevError: hadErrors = true
  if hadErrors:
    return ("", false)

  let (asmText, cgDiags) = generateModule(unit, f)
  for d in dedupDiags(cgDiags):
    reportWithSource(d, src, not cfg.noColor)
    if d.severity == sevError: hadErrors = true
  if hadErrors:
    return ("", false)

  let base = f.extractFilename.changeFileExt("")
  let asmPath = tmpDir / (base & "_" & $hash(f) & ".s")
  writeFile(asmPath, asmText)

  let objPath = if finalObjPath.len > 0: finalObjPath
                else: tmpDir / (base & "_" & $hash(f) & ".o")
  let (asOk, asOut) = assembleFile(asmPath, objPath)
  if not asOk:
    stderr.writeLine "zcc: as: błąd asemblacji " & f & ":"
    stderr.writeLine asOut
    return ("", false)
  (objPath, true)

when isMainModule:
  let cfg = parseArgs()
  if cfg.inputs.len == 0:
    stderr.writeLine "zcc: brak plików wejściowych"
    quit(1)

  let tgt = resolveTarget(cfg.targetTriple)
  if cfg.verbose:
    stderr.writeLine "zcc: std=" & $cfg.std & " link=" & $cfg.link &
      " opt=" & $cfg.opt & " target=" & tgt.llvmTriple &
      " hardening=" & $cfg.hardening & " lto=" & cfg.ltoMode &
      " reproducible=" & $cfg.reproducible & " jobs=" & $jobCount(cfg) &
      " inputs=" & $cfg.inputs

  # --- hardening ---
  let hard = resolveHardeningFlags(cfg, tgt)
  for w in hard.warnings:
    stderr.writeLine "zcc: warning: " & w
  if cfg.verbose and hard.flags.len > 0:
    stderr.writeLine "zcc: hardening flags: " & hard.flags.join(" ")

  # --- sanitizery ---
  if cfg.sanitizers.len > 0:
    var sans: seq[SanitizerKind] = @[]
    for s in cfg.sanitizers:
      try: sans.add parseSanitizer(s)
      except ValueError as e:
        stderr.writeLine "zcc: " & e.msg
        quit(1)
    let sanRes = resolveSanitizeFlags(sans, cfg, tgt)
    for e in sanRes.errors:
      stderr.writeLine "zcc: error: " & e
    if sanRes.errors.len > 0: quit(1)
    for w in sanRes.warnings:
      stderr.writeLine "zcc: warning: " & w
    if cfg.verbose:
      stderr.writeLine "zcc: sanitize flags: " & sanRes.flags.join(" ")

  # --- LTO ---
  let ltoRes = resolveLtoFlags(parseLtoMode(cfg.ltoMode), jobCount(cfg))
  if cfg.verbose and ltoRes.note.len > 0:
    stderr.writeLine "zcc: lto: " & ltoRes.note

  # --- reproducible builds ---
  if cfg.reproducible:
    let root = if cfg.inputs.len > 0: cfg.inputs[0].parentDir.absolutePath else: getCurrentDir()
    let reproRes = resolveReproducibleFlags(cfg, root)
    if cfg.verbose:
      stderr.writeLine "zcc: reproducible flags: " & reproRes.compileFlags.join(" ")

  # --- pluginy ---
  var loadedPlugins: seq[plugins.LoadedPlugin] = @[]
  if cfg.pluginPaths.len > 0:
    loadedPlugins = loadAllPlugins(cfg.pluginPaths)

  # --- -MM / -MMD ---
  if cfg.depMode == depMM:
    for f in cfg.inputs:
      stdout.write makeRuleFor(f, cfg)
    quit(0)
  if cfg.depMode == depMMD:
    for f in cfg.inputs:
      writeDepFile(f, cfg)
      if cfg.verbose:
        stderr.writeLine "zcc: zapisano .d dla " & f

  # --- cache (plan - realne spięcie czeka na codegen, patrz ROADMAP) ---
  if cfg.cacheEnabled and cfg.outKind == okObjectOnly:
    for f in cfg.inputs:
      let key = cache.computeKey(f, cfg)
      let entry = cache.lookup(cfg, key)
      if cfg.verbose:
        stderr.writeLine "zcc: cache " & (if entry.hit: "HIT " else: "MISS ") &
          f & " -> " & entry.objPath

  if cfg.outKind == okObjectOnly and cfg.inputs.len > 1 and cfg.verbose:
    stderr.writeLine "zcc: równoległy plan builda: " & $jobCount(cfg) &
      " jobów dla " & $cfg.inputs.len & " plików (self.exe=" & getAppFilename() & ")"

  # --- codegen x86-64 Linux: -S / -c / link -> plik wykonywalny ---
  if tgt.arch != arX86_64 or tgt.os != tosLinux:
    stderr.writeLine "zcc: codegen obsługuje w tej iteracji tylko x86_64-linux " &
      "(zażądano: " & tgt.llvmTriple & ") - patrz docs/ROADMAP.md (etap 3+ dla " &
      "kolejnych architektur)"
    quit(1)

  let tmpDir = getTempDir() / "zcc-build-" & $getCurrentProcessId()
  createDir(tmpDir)

  case cfg.outKind
  of okAssemblyOnly:
    var anyFail = false
    for f in cfg.inputs:
      var src: string
      try: src = pp.preprocessFile(f, cfg.std, cfg.includeDirs)
      except pp.PreprocessError as e:
        stderr.writeLine "zcc: " & e.msg
        anyFail = true
        continue
      var lx = newLexer(src, f, cfg.std)
      var toks: seq[Token] = @[]
      for tok in lx.tokens(): toks.add tok
      var hadErr = false
      for d in lx.diags:
        reportWithSource(d, src, not cfg.noColor)
        if d.severity == sevError: hadErr = true
      let (unit, parseDiags) = parseTokens(toks, f, cfg.std)
      var allDiags = parseDiags
      allDiags.add runSema(unit, f)
      for d in dedupDiags(allDiags):
        reportWithSource(d, src, not cfg.noColor)
        if d.severity == sevError: hadErr = true
      if hadErr: anyFail = true; continue
      let (asmText, cgDiags) = generateModule(unit, f)
      for d in dedupDiags(cgDiags):
        reportWithSource(d, src, not cfg.noColor)
        if d.severity == sevError: hadErr = true
      if hadErr: anyFail = true; continue
      let outPath = if cfg.output.len > 0 and cfg.inputs.len == 1: cfg.output
                    else: f.changeFileExt("s")
      writeFile(outPath, asmText)
      if cfg.verbose: stderr.writeLine "zcc: " & f & " -> " & outPath
    removeDir(tmpDir)
    quit(if anyFail: 1 else: 0)

  of okObjectOnly:
    var anyFail = false
    for f in cfg.inputs:
      let outPath = if cfg.output.len > 0 and cfg.inputs.len == 1: cfg.output
                    else: f.changeFileExt("o")
      if cfg.cacheEnabled:
        let key = cache.computeKey(f, cfg)
        let entry = cache.lookup(cfg, key)
        if entry.hit:
          copyFile(entry.objPath, outPath)
          if cfg.verbose: stderr.writeLine "zcc: cache HIT " & f & " -> " & outPath
          continue
        let (objPath, ok) = compileToObject(f, cfg, tmpDir)
        if not ok: anyFail = true; continue
        copyFile(objPath, outPath)
        cache.store(cfg, key, objPath)
      else:
        let (objPath, ok) = compileToObject(f, cfg, tmpDir)
        if not ok: anyFail = true; continue
        copyFile(objPath, outPath)
      if cfg.verbose: stderr.writeLine "zcc: " & f & " -> " & outPath
    removeDir(tmpDir)
    quit(if anyFail: 1 else: 0)

  of okExecutable, okSharedLib:
    if cfg.outKind == okSharedLib:
      stderr.writeLine "zcc: linkowanie bibliotek współdzielonych (-shared) " &
        "nieobsługiwane w tej iteracji codegenu (wymaga PIC/Scrt1.o - TODO, " &
        "patrz docs/ROADMAP.md) - użyj -c i zlinkuj zewnętrznym narzędziem"
      quit(1)
    var objPaths: seq[string] = @[]
    var anyFail = false
    for f in cfg.inputs:
      if f.toLowerAscii.endsWith(".o") or f.toLowerAscii.endsWith(".a"):
        # gotowy obiekt/archiwum - przekaż bezpośrednio do linkera, bez
        # przepuszczania przez front-end (to nie jest źródło C)
        objPaths.add f
        continue
      if cfg.cacheEnabled:
        let key = cache.computeKey(f, cfg)
        let entry = cache.lookup(cfg, key)
        if entry.hit:
          if cfg.verbose: stderr.writeLine "zcc: cache HIT " & f
          objPaths.add entry.objPath
          continue
        let (objPath, ok) = compileToObject(f, cfg, tmpDir)
        if not ok: anyFail = true; continue
        cache.store(cfg, key, objPath)
        objPaths.add objPath
      else:
        let (objPath, ok) = compileToObject(f, cfg, tmpDir)
        if not ok: anyFail = true; continue
        objPaths.add objPath
    if anyFail or objPaths.len == 0:
      removeDir(tmpDir)
      quit(1)

    let outPath = if cfg.output.len > 0: cfg.output else: "a.out"
    let (linkOk, linkOut) = linkExecutable(objPaths, outPath, tgt,
      staticLink = (cfg.link == lmStatic) and cfg.outKind == okExecutable,
      extraLibs = cfg.libs, extraLibDirs = cfg.libDirs)
    removeDir(tmpDir)
    if not linkOk:
      stderr.writeLine "zcc: ld: błąd linkowania:"
      stderr.writeLine linkOut
      let suggestions = analyzeLinkerFailure(linkOut)
      let formatted = formatSuggestions(suggestions)
      if formatted.len > 0: stderr.writeLine formatted
      quit(1)
    when defined(posix):
      discard execShellCmd("chmod +x " & outPath.quoteShell)
    if cfg.verbose: stderr.writeLine "zcc: -> " & outPath
    quit(0)

  else:
    stderr.writeLine "zcc: nieobsługiwany tryb wyjścia: " & $cfg.outKind
    quit(1)
