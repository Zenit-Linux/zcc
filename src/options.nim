type
  CStd* = enum
    stdC99 = "c99"
    stdC11 = "c11"
    stdC17 = "c17"
    stdC23 = "c23"

  LinkMode* = enum
    lmStatic   ## domyślne
    lmDynamic  ## -dynamic / --dyn-link

  OutputKind* = enum
    okExecutable   ## domyślnie
    okObjectOnly   ## -c
    okPreprocessOnly ## -E
    okAssemblyOnly ## -S
    okSharedLib    ## -shared

  OptLevel* = enum
    opt0 = "0", opt1 = "1", opt2 = "2", opt3 = "3", optS = "s"

  HardeningLevel* = enum
    hardOff       ## --no-hardened : brak dodatkowych zabezpieczeń
    hardDefault   ## domyślny: stack-protector-strong, FORTIFY_SOURCE=2, PIE
    hardMax       ## --hardened=max : + CFI/CET/PAC-BTI, static-pie gdzie możliwe

  DepMode* = enum
    depNone       ## bez generowania zależności
    depMM         ## -MM : wypisz reguły make na stdout, nie kompiluj
    depMMD        ## -MMD : generuj plik .d obok wyjścia, kompiluj normalnie

  Config* = object
    inputs*: seq[string]
    output*: string
    std*: CStd
    link*: LinkMode
    outKind*: OutputKind
    opt*: OptLevel
    debugInfo*: bool
    includeDirs*: seq[string]
    defines*: seq[(string, string)]
    libDirs*: seq[string]
    libs*: seq[string]
    warningsAsErrors*: bool
    verbose*: bool
    noColor*: bool          # wyłącz kolorowanie diagnostyki (np. dla CI)
    # --- hardening ---
    hardening*: HardeningLevel
    # --- cross-compilation ---
    targetTriple*: string   # "" = host; inaczej np. "aarch64-linux-musl"
    # --- tooling / build perf ---
    depMode*: DepMode
    depOutFile*: string     # dla -MMD: docelowy plik .d (domyślnie <obj>.d)
    jobs*: int               # 0 = auto (liczba rdzeni)
    cacheEnabled*: bool
    cacheDir*: string        # "" = domyślny (~/.cache/zcc)
    usePch*: bool             # prekompilowane nagłówki
    # --- reproducible builds ---
    reproducible*: bool       # --reproducible
    # --- sanitizery (dev/CI, patrz sanitize.nim) ---
    sanitizers*: seq[string]  # nazwy jak przekazane w -fsanitize=a,b,c
    # --- LTO ---
    ltoMode*: string          # "off" | "thin" | "full"
    # --- plugin API (patrz plugins.nim) ---
    pluginPaths*: seq[string] # --plugin=<ścieżka .so>

proc defaultConfig*(): Config =
  Config(
    inputs: @[],
    output: "",
    std: stdC17,
    link: lmStatic,        # <-- statyczne linkowanie domyślnie
    outKind: okExecutable,
    opt: opt0,
    debugInfo: false,
    includeDirs: @[],
    defines: @[],
    libDirs: @[],
    libs: @[],
    warningsAsErrors: false,
    verbose: false,
    noColor: false,
    hardening: hardDefault,   # <-- agresywniejszy default niż gcc
    targetTriple: "",
    depMode: depNone,
    depOutFile: "",
    jobs: 0,
    cacheEnabled: true,
    cacheDir: "",
    usePch: true,
    reproducible: false,
    sanitizers: @[],
    ltoMode: "off",
    pluginPaths: @[]
  )
