type LtoMode* = enum
  ltoOff
  ltoThin   ## zalecany default przy -O2/-O3: dużo korzyści, mniejszy koszt cache/RAM
  ltoFull   ## maksymalna optymalizacja międzymodułowa, kosztowna w RAM/czasie linkowania

proc parseLtoMode*(s: string): LtoMode =
  case s
  of "off", "": ltoOff
  of "thin": ltoThin
  of "full": ltoFull
  else: raise newException(ValueError, "nieznany tryb LTO: " & s)

type LtoResult* = object
  compileFlags*: seq[string]   ## flagi na etapie kompilacji (-c)
  linkFlags*: seq[string]      ## flagi na etapie linkowania
  cacheKeySuffix*: string      ## dopisywane do klucza cache.computeKey przy LTO
  note*: string

proc resolveLtoFlags*(mode: LtoMode, jobs: int): LtoResult =
  case mode
  of ltoOff:
    LtoResult(compileFlags: @[], linkFlags: @[], cacheKeySuffix: "", note: "")
  of ltoThin:
    LtoResult(
      compileFlags: @["-flto=thin"],
      linkFlags: @["-flto=thin", "-flto-jobs=" & $jobs],
      cacheKeySuffix: "lto-thin",
      note: "ThinLTO: cache per-TU nadal w większości trafny (analiza płytka)")
  of ltoFull:
    LtoResult(
      compileFlags: @["-flto=full"],
      linkFlags: @["-flto=full"],
      cacheKeySuffix: "lto-full",
      note: "Pełny LTO: cache per-TU MNIEJ skuteczny - wynik obiektu " &
            "zależy pośrednio od całego grafu linkowania; realny cache " &
            "wymagałby klucza na poziomie linkowania (TODO, nieopisane " &
            "jeszcze w cache.nim - patrz docs/ARCHITECTURE.md)")
