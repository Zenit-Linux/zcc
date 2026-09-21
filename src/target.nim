import std/[strutils, os, osproc]

type
  Arch* = enum arX86_64, arAArch64, arRiscv64, arUnknown
  TargetOS* = enum tosLinux, tosUnknown
  TargetAbi* = enum tabiGnu, tabiMusl, tabiUnknown

  Target* = object
    arch*: Arch
    os*: TargetOS
    abi*: TargetAbi
    raw*: string   ## oryginalny triple podany przez użytkownika (do logów)

proc parseTarget*(triple: string): Target =
  ## Parsuje triple typu "aarch64-linux-musl" / "x86_64-linux-gnu".
  ## Nieznane/pominięte człony zostają Unknown - wtedy wyżej w driverze
  ## należy zgłosić błąd, jeśli coś jest krytycznie potrzebne (np. arch).
  result.raw = triple
  result.arch = arUnknown
  result.os = tosUnknown
  result.abi = tabiUnknown
  for part in triple.split('-'):
    case part.toLowerAscii
    of "x86_64", "amd64": result.arch = arX86_64
    of "aarch64", "arm64": result.arch = arAArch64
    of "riscv64": result.arch = arRiscv64
    of "linux": result.os = tosLinux
    of "gnu", "gnueabi", "gnueabihf": result.abi = tabiGnu
    of "musl", "musleabi", "musleabihf": result.abi = tabiMusl
    else: discard

proc hostTarget*(): Target =
  ## Target domyślny = host, gdy użytkownik nie poda --target=.
  ## Zenit Linux domyślnie na musl (patrz docs/ARCHITECTURE.md, decyzja
  ## o statycznym linkowaniu) - stąd abi=musl jako domyślne, nie gnu.
  when defined(amd64):
    result.arch = arX86_64
  elif defined(arm64):
    result.arch = arAArch64
  else:
    result.arch = arUnknown
  result.os = tosLinux
  result.abi = tabiMusl
  result.raw = "host"

proc isValid*(t: Target): bool =
  t.arch != arUnknown and t.os != tosUnknown and t.abi != tabiUnknown

proc llvmTriple*(t: Target): string =
  ## Triple w formacie akceptowanym przez LLVM (do -target / LLVMTargetRef).
  let a = case t.arch
    of arX86_64: "x86_64"
    of arAArch64: "aarch64"
    of arRiscv64: "riscv64"
    of arUnknown: "unknown"
  let o = case t.os
    of tosLinux: "linux"
    of tosUnknown: "unknown"
  let ab = case t.abi
    of tabiGnu: "gnu"
    of tabiMusl: "musl"
    of tabiUnknown: "unknown"
  a & "-" & o & "-" & ab

## Szuka libgcc.a - biblioteki wsparcia runtime (m.in. `_Unwind_Resume`,
## konwersje `__unordtf2`/`__letf2` dla `long double`) potrzebnej przy
## STATYCZNYM linkowaniu z glibc - glibc.a odwołuje się do tych symboli
## nawet w programach, które same w sobie ich nie używają (m.in. przez
## kod obsługi wyjątków/informacji o `long double` w printf). Dostarcza
## ją zwykle gcc; pytamy go o ścieżkę zamiast linkować przez niego -
## to nie jest "użycie gcc jako kompilatora", tylko zlokalizowanie
## gotowej biblioteki statycznej, podobnie jak zwykłe `-lc`. musl nie ma
## tego problemu (nie potrzeba libgcc do podstawowego statycznego
## linkowania), więc to dotyczy tylko ABI gnu.
proc findLibgcc*(): string =
  let gccExe = findExe("gcc")
  if gccExe.len == 0: return ""
  try:
    let (output, code) = execCmdEx(gccExe & " -print-libgcc-file-name")
    if code == 0:
      let p = output.strip()
      if p.len > 0 and fileExists(p): return p
  except OSError:
    discard
  result = ""

## `libgcc.a` samo w sobie zostawia `_Unwind_Resume` (rozwijanie stosu
## przy wyjątkach) niezdefiniowanym - potrzebna jeszcze `libgcc_eh.a`
## (tak samo robi to `gcc -static` pod spodem, dodając obie).
proc findLibgccEh*(): string =
  let gccExe = findExe("gcc")
  if gccExe.len == 0: return ""
  try:
    let (output, code) = execCmdEx(gccExe & " -print-file-name=libgcc_eh.a")
    if code == 0:
      let p = output.strip()
      if p.len > 0 and p != "libgcc_eh.a" and fileExists(p): return p
  except OSError:
    discard
  result = ""

proc resolveTarget*(triple: string): Target =
  if triple.len == 0 or triple == "host":
    hostTarget()
  else:
    parseTarget(triple)

# ============================== lokalizacja libc/crt na hoście ==============================

type LibcPaths* = object
  found*: bool
  crt1*, crti*, crtn*: string
  libDir*: string
  dynLinker*: string
  abi*: TargetAbi

## Szuka na hoście obiektów startowych (crt1.o/crti.o/crtn.o) i katalogu
## libc pasujących do żądanej ABI, z fallbackiem na drugą ABI, jeśli
## preferowanej brak. Zenit Linux (docelowa dystrybucja projektu) ma być
## na musl, ale większość maszyn deweloperskich (w tym to środowisko) ma
## tylko glibc - brak musla nie powinien blokować budowy tutaj, stąd ta
## próba obu zamiast twardego wymagania jednej. Pełna cross-kompilacja
## (inny sysroot/architektura niż hosta) jest świadomym TODO tej iteracji
## codegenu - patrz ARCHITECTURE.md/ROADMAP.md.
proc findCLibPaths*(preferred: TargetAbi): LibcPaths =
  type Candidate = tuple[abi: TargetAbi, dir: string, dynLinker: string]
  let candidates: seq[Candidate] =
    @[
      (tabiMusl, "/usr/lib/x86_64-linux-musl", "/lib/ld-musl-x86_64.so.1"),
      (tabiGnu, "/usr/lib/x86_64-linux-gnu", "/lib64/ld-linux-x86-64.so.2"),
      (tabiGnu, "/usr/lib64", "/lib64/ld-linux-x86-64.so.2"),
    ]
  proc tryDir(dir, dynLinker: string, abi: TargetAbi): LibcPaths =
    let c1 = dir / "crt1.o"
    let c2 = dir / "crti.o"
    let c3 = dir / "crtn.o"
    if fileExists(c1) and fileExists(c2) and fileExists(c3):
      return LibcPaths(found: true, crt1: c1, crti: c2, crtn: c3,
                        libDir: dir, dynLinker: dynLinker, abi: abi)
    LibcPaths(found: false)

  for c in candidates:
    if c.abi == preferred:
      let r = tryDir(c.dir, c.dynLinker, c.abi)
      if r.found: return r
  for c in candidates:
    if c.abi != preferred:
      let r = tryDir(c.dir, c.dynLinker, c.abi)
      if r.found: return r
  LibcPaths(found: false)
