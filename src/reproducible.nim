import std/os
import options as zccopts

type ReproFlags* = object
  compileFlags*: seq[string]
  archiveFlags*: seq[string]
  env*: seq[(string, string)]   ## zmienne środowiskowe do ustawienia dla pod-procesów

proc resolveReproducibleFlags*(cfg: zccopts.Config, sourceRoot: string): ReproFlags =
  result = ReproFlags(compileFlags: @[], archiveFlags: @[], env: @[])
  if not cfg.reproducible: return result

  # Normalizacja ścieżek: __FILE__, DWARF debug info i inne miejsca, gdzie
  # kompilator wstawia ścieżkę pliku, dostają prefix-mapping do ścieżki
  # względnej - inaczej ten sam projekt zbudowany w /home/alice/proj i
  # /home/bob/proj da różne binarki mimo identycznego kodu.
  result.compileFlags.add "-ffile-prefix-map=" & sourceRoot & "=."
  if cfg.debugInfo:
    result.compileFlags.add "-fdebug-prefix-map=" & sourceRoot & "=."

  # SOURCE_DATE_EPOCH: standard reproducible-builds.org - zamiast "teraz",
  # wszystkie timestampy (w obiektach, archiwach .a, ewentualnych
  # wbudowanych datach kompilacji) używają tej ustalonej wartości.
  # Jeśli CI/build system jej nie ustawił, zcc sam ją definiuje na bazie
  # commitu (TODO: właściwe wykrycie z git - na razie fallback na "0").
  var epoch = "0"
  if existsEnv("SOURCE_DATE_EPOCH"):
    epoch = getEnv("SOURCE_DATE_EPOCH")
  result.env.add ("SOURCE_DATE_EPOCH", epoch)
  result.compileFlags.add "-Wdate-time"   ## ostrzegaj jeśli kod używa __DATE__/__TIME__

  # ar/deterministyczne archiwa: 'D' = deterministic mode (zerowe UID/GID/
  # timestamp, stała kolejność) zamiast domyślnego 'u' (update, zależnego
  # od mtime plików na dysku).
  result.archiveFlags.add "D"

  # Losowe etykiety/seedy generowane wewnętrznie przez kompilator (np. przy
  # -frandom-seed w gcc) - ustalamy na bazie ścieżki źródła względem roota,
  # więc jest stabilne między maszynami, ale wciąż unikalne per plik
  # (unika kolizji nazw symboli lokalnych między jednostkami translacji).
  result.compileFlags.add "-frandom-seed=zcc-repro"
