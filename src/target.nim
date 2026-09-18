import std/strutils

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

proc resolveTarget*(triple: string): Target =
  if triple.len == 0 or triple == "host":
    hostTarget()
  else:
    parseTarget(triple)
