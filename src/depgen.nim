import std/[os, strutils, sets]
import options as zccopts

proc scanIncludes*(path: string): seq[tuple[header: string, isSystem: bool]] =
  result = @[]
  if not fileExists(path): return
  for line in lines(path):
    let l = line.strip()
    if l.startsWith("#include"):
      let rest = l["#include".len .. ^1].strip()
      if rest.len >= 2:
        if rest[0] == '"':
          let e = rest.find('"', 1)
          if e > 1: result.add (rest[1 ..< e], false)
        elif rest[0] == '<':
          let e = rest.find('>', 1)
          if e > 1: result.add (rest[1 ..< e], true)

proc resolveHeader*(name: string, includeDirs: seq[string],
                     sourceDir: string, isSystem: bool): string =
  ## Uproszczona rezolucja: lokalne #include"" najpierw obok źródła,
  ## potem -I; <> tylko przez -I. Prawdziwe ścieżki systemowe
  ## (/usr/include itp.) do dodania jako builtin lista w kolejnym etapie.
  if not isSystem:
    let local = sourceDir / name
    if fileExists(local): return local
  for d in includeDirs:
    let cand = d / name
    if fileExists(cand): return cand
  return ""

proc collectHeaderClosure*(sourcePath: string, includeDirs: seq[string]): seq[string] =
  ## Tranzytywne zamknięcie nagłówków (nagłówki nagłówków też skanujemy).
  var seen = initHashSet[string]()
  var stack = @[sourcePath]
  var headers: seq[string] = @[]
  seen.incl sourcePath
  while stack.len > 0:
    let cur = stack.pop()
    for (h, isSys) in scanIncludes(cur):
      let resolved = resolveHeader(h, includeDirs, cur.parentDir, isSys)
      if resolved.len > 0 and resolved notin seen:
        seen.incl resolved
        headers.add resolved
        stack.add resolved
  result = headers

proc objNameFor(sourcePath: string, cfg: zccopts.Config): string =
  if cfg.output.len > 0: cfg.output
  else: sourcePath.changeFileExt("o")

proc makeRuleFor*(sourcePath: string, cfg: zccopts.Config): string =
  let headers = collectHeaderClosure(sourcePath, cfg.includeDirs)
  var line = objNameFor(sourcePath, cfg) & ": " & sourcePath
  for h in headers:
    line &= " \\\n  " & h
  result = line & "\n"

proc writeDepFile*(sourcePath: string, cfg: zccopts.Config) =
  let rule = makeRuleFor(sourcePath, cfg)
  let target = if cfg.depOutFile.len > 0: cfg.depOutFile
               else: objNameFor(sourcePath, cfg).changeFileExt("d")
  writeFile(target, rule)
