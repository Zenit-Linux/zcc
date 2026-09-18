import std/sequtils
import options as zccopts
import target

proc pieSafeWithStatic*(t: Target): bool =
  t.abi == tabiMusl

type HardeningResult* = object
  flags*: seq[string]
  warnings*: seq[string]

proc resolveHardeningFlags*(cfg: zccopts.Config, t: Target): HardeningResult =
  result = HardeningResult(flags: @[], warnings: @[])
  if cfg.hardening == hardOff:
    return result

  # --- poziom "default": włączony zawsze, chyba że jawnie wyłączony ---
  result.flags.add "-fstack-protector-strong"
  result.flags.add "-D_FORTIFY_SOURCE=2"
  result.flags.add "-fstack-clash-protection"
  var pieRequested = true
  result.flags.add "-fPIE"

  if cfg.link == lmStatic:
    if pieSafeWithStatic(t):
      result.flags.add "-static-pie"
    else:
      result.warnings.add(
        "hardening: pełny -static + PIE nie jest bezpiecznie wspierany dla " &
        "abi=" & $t.abi & " -> PIE wyłączony dla tej binarki " &
        "(użyj --target=...-musl dla pełnego static-pie, albo -dynamic)")
      result.flags.add "-static"
      pieRequested = false
      result.flags = result.flags.filterIt(it != "-fPIE")

  # --- poziom "max": dodatkowo CFI/CET/PAC-BTI zależnie od architektury ---
  if cfg.hardening == hardMax:
    case t.arch
    of arX86_64:
      result.flags.add "-fcf-protection=full"      # Intel CET
    of arAArch64:
      result.flags.add "-mbranch-protection=standard"  # ARM PAC + BTI
    else:
      result.warnings.add(
        "hardening=max: brak wsparcia sprzętowego CFI dla arch=" & $t.arch &
        " - pomijam (aplikuję tylko hardening programowy)")

  if not pieRequested and cfg.hardening == hardMax:
    result.warnings.add(
      "hardening=max: PAC/BTI/CET nadal działają bez PIE, ale pełna " &
      "korzyść (ASLR binarki) jest ograniczona przy -static na abi=gnu")
