import std/os
import options as zccopts

type
  PchEntry* = object
    headerListHash*: string
    pchPath*: string
    valid*: bool

proc pchDirFor*(cfg: zccopts.Config): string =
  (if cfg.cacheDir.len > 0: cfg.cacheDir else: getHomeDir() / ".cache" / "zcc") / "pch"

## Placeholder - zwraca zawsze "brak trafienia", dopóki nie ma czego
## serializować (brak jeszcze AST/sema). Podpięcie realnej serializacji
## nastąpi w etapie 2/3 razem z parserem.
proc lookupPch*(cfg: zccopts.Config, headerListHash: string): PchEntry =
  if not cfg.usePch:
    return PchEntry(headerListHash: headerListHash, pchPath: "", valid: false)
  let dir = pchDirFor(cfg)
  let candidate = dir / (headerListHash & ".pch")
  PchEntry(headerListHash: headerListHash, pchPath: candidate,
           valid: fileExists(candidate))
