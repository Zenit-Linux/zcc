
import std/[strutils, tables, os]
import options as zccopts

type TomlValue = object
  case isArray: bool
  of true: arr: seq[string]
  of false: str: string

type TomlDoc = Table[string, Table[string, TomlValue]]

proc stripComment(line: string): string =
  var inStr = false
  for i, c in line:
    if c == '"': inStr = not inStr
    if c == '#' and not inStr:
      return line[0 ..< i]
  line

proc parseValue(raw: string): TomlValue =
  let v = raw.strip()
  if v.startsWith("[") and v.endsWith("]"):
    var items: seq[string] = @[]
    let inner = v[1 ..< ^1]
    for part in inner.split(','):
      let p = part.strip().strip(chars = {'"'})
      if p.len > 0: items.add p
    return TomlValue(isArray: true, arr: items)
  if v.startsWith("\"") and v.endsWith("\"") and v.len >= 2:
    return TomlValue(isArray: false, str: v[1 ..< ^1])
  return TomlValue(isArray: false, str: v)  # liczby/bool trzymane jako tekst

proc parseToml(content: string): TomlDoc =
  result = initTable[string, Table[string, TomlValue]]()
  var section = ""
  result[section] = initTable[string, TomlValue]()
  for rawLine in content.splitLines():
    let line = stripComment(rawLine).strip()
    if line.len == 0: continue
    if line.startsWith("[") and line.endsWith("]"):
      section = line[1 ..< ^1].strip()
      if section notin result:
        result[section] = initTable[string, TomlValue]()
      continue
    let eq = line.find('=')
    if eq < 0: continue
    let key = line[0 ..< eq].strip()
    let val = parseValue(line[eq+1 .. ^1])
    result[section][key] = val

proc getStr(doc: TomlDoc, section, key: string, default = ""): string =
  if section in doc and key in doc[section] and not doc[section][key].isArray:
    return doc[section][key].str
  default

proc getBool(doc: TomlDoc, section, key: string, default = false): bool =
  let s = getStr(doc, section, key, $default)
  s == "true"

proc getArr(doc: TomlDoc, section, key: string): seq[string] =
  if section in doc and key in doc[section] and doc[section][key].isArray:
    return doc[section][key].arr
  @[]

## Wczytuje `zcc.toml` z podanego katalogu (albo najbliższego rodzica) i
## NAKŁADA jego wartości na istniejący Config jako nowe domyślne - flagi
## z linii poleceń, sparsowane już wcześniej w main.nim, powinny mieć
## pierwszeństwo (wołający decyduje o kolejności merge, patrz main.nim).
proc loadProjectConfig*(dir: string): zccopts.Config =
  result = zccopts.defaultConfig()
  var d = dir
  var path = ""
  for _ in 0 ..< 32:   # ogranicznik na wypadek dziwnej struktury katalogów
    let cand = d / "zcc.toml"
    if fileExists(cand):
      path = cand
      break
    let parent = d.parentDir
    if parent == d: break
    d = parent
  if path.len == 0: return result

  let doc = parseToml(readFile(path))

  let stdStr = getStr(doc, "build", "std")
  case stdStr
  of "c99": result.std = stdC99
  of "c11": result.std = stdC11
  of "c17", "c18": result.std = stdC17
  of "c23": result.std = stdC23
  else: discard

  if getStr(doc, "build", "link") == "dynamic":
    result.link = lmDynamic

  let hardStr = getStr(doc, "hardening", "level")
  case hardStr
  of "off": result.hardening = hardOff
  of "max": result.hardening = hardMax
  else: discard

  result.targetTriple = getStr(doc, "build", "target", result.targetTriple)
  result.includeDirs = getArr(doc, "build", "include_dirs")
  result.libs = getArr(doc, "build", "libs")
  result.ltoMode = getStr(doc, "build", "lto", "off")
  result.reproducible = getBool(doc, "build", "reproducible", false)
  result.sanitizers = getArr(doc, "dev", "sanitizers")
  result.pluginPaths = getArr(doc, "plugins", "paths")
