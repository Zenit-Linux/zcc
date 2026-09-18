import std/[os, hashes, strutils]
import options as zccopts

type
  CacheEntry* = object
    key*: string
    objPath*: string   ## docelowa ścieżka w cache, gdzie leży .o
    hit*: bool

proc cacheDirFor*(cfg: zccopts.Config): string =
  if cfg.cacheDir.len > 0: cfg.cacheDir
  else: getHomeDir() / ".cache" / "zcc"

proc computeKey*(sourcePath: string, cfg: zccopts.Config): string =
  let content = readFile(sourcePath)
  var h = hash(content)
  h = h !& hash($cfg.std)
  h = h !& hash($cfg.opt)
  h = h !& hash(cfg.debugInfo)
  h = h !& hash(cfg.targetTriple)
  h = h !& hash($cfg.hardening)
  h = h !& hash($cfg.link)
  for inc in cfg.includeDirs:
    h = h !& hash(inc)
  for (k, v) in cfg.defines:
    h = h !& hash(k) !& hash(v)
  h = !$h
  result = "zcc-" & toHex(cast[uint64](h))

proc lookup*(cfg: zccopts.Config, key: string): CacheEntry =
  let dir = cacheDirFor(cfg)
  let candidate = dir / (key & ".o")
  CacheEntry(key: key, objPath: candidate, hit: fileExists(candidate))

proc store*(cfg: zccopts.Config, key: string, compiledObjPath: string) =
  let dir = cacheDirFor(cfg)
  createDir(dir)
  copyFile(compiledObjPath, dir / (key & ".o"))

proc stats*(cfg: zccopts.Config): tuple[entries: int, bytes: int64] =
  let dir = cacheDirFor(cfg)
  if not dirExists(dir): return (0, 0'i64)
  var count = 0
  var total: int64 = 0
  for f in walkFiles(dir / "*.o"):
    inc count
    total += getFileSize(f)
  (count, total)

proc clear*(cfg: zccopts.Config) =
  let dir = cacheDirFor(cfg)
  if dirExists(dir):
    removeDir(dir)
