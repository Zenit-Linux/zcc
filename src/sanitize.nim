import std/strutils
import options as zccopts
import target

type
  SanitizerKind* = enum
    sanAddress    ## -fsanitize=address (ASan): use-after-free, overflow
    sanUndefined  ## -fsanitize=undefined (UBSan): UB (overflow, null deref...)
    sanThread     ## -fsanitize=thread (TSan): data race - WYKLUCZA się z ASan
    sanMemory     ## -fsanitize=memory (MSan): odczyt niezainicjalizowanej pamięci
                   ## - WYMAGA że WSZYSTKIE linkowane liby też są nim zbudowane

proc parseSanitizer*(name: string): SanitizerKind =
  case name
  of "address": sanAddress
  of "undefined": sanUndefined
  of "thread": sanThread
  of "memory": sanMemory
  else: raise newException(ValueError, "nieznany sanitizer: " & name)

proc flagFor(s: SanitizerKind): string =
  case s
  of sanAddress: "address"
  of sanUndefined: "undefined"
  of sanThread: "thread"
  of sanMemory: "memory"

type SanitizeResult* = object
  flags*: seq[string]
  warnings*: seq[string]
  errors*: seq[string]   ## kombinacje niedozwolone - blokują build, nie tylko ostrzegają

proc resolveSanitizeFlags*(sanitizers: seq[SanitizerKind], cfg: zccopts.Config,
                            t: Target): SanitizeResult =
  result = SanitizeResult(flags: @[], warnings: @[], errors: @[])
  if sanitizers.len == 0: return result

  # ASan i TSan/MSan się wzajemnie wykluczają (współdzielą mechanizm
  # przechwytywania alokatora / shadow memory w niekompatybilny sposób)
  if sanAddress in sanitizers and (sanThread in sanitizers or sanMemory in sanitizers):
    result.errors.add "sanitizery 'address' i 'thread'/'memory' nie mogą być użyte razem"
    return result
  if sanThread in sanitizers and sanMemory in sanitizers:
    result.errors.add "sanitizery 'thread' i 'memory' nie mogą być użyte razem"
    return result

  var names: seq[string] = @[]
  for s in sanitizers: names.add flagFor(s)
  result.flags.add "-fsanitize=" & names.join(",")
  result.flags.add "-fno-omit-frame-pointer"   ## potrzebne dla czytelnych stack trace
  result.flags.add "-g"                         ## symbolizacja bez -g jest bezużyteczna

  # Statyczne linkowanie + sanitizery: ASan/TSan/MSan runtime tradycyjnie
  # jest dostarczany jako .so (dlopen'owalny interceptor). Pełny -static
  # z sanitizerami bywa niewspierany bez specjalnie zbudowanego runtime.
  if cfg.link == lmStatic:
    result.warnings.add(
      "sanitizery + -static: wymaga statycznego runtime sanitizera " &
      "(np. libclang_rt.*-static.a) - jeśli toolchain go nie dostarcza, " &
      "zcc automatycznie przełączy tę binarkę na -dynamic (patrz --verbose)")

  if sanMemory in sanitizers:
    result.warnings.add(
      "sanitize=memory: WSZYSTKIE statycznie/dynamicznie linkowane " &
      "biblioteki (w tym libc) muszą być zbudowane z MSan, inaczej " &
      "fałszywe pozytywy - zwykle sensowne tylko w dedykowanym MSan-buildzie")

  if sanThread in sanitizers and t.arch == arAArch64:
    result.warnings.add "sanitize=thread: wsparcie na aarch64 bywa niepełne w części wersji LLVM - zweryfikuj lokalnie"
