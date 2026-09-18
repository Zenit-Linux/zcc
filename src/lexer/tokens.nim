import ../options

type
  TokenKind* = enum
    tkEOF
    tkIdent
    tkIntLit
    tkFloatLit
    tkCharLit
    tkStringLit
    tkKeyword
    tkPunct
    tkComment      # zachowywane tylko w trybie -E / narzędziach
    tkUnknown

  Token* = object
    kind*: TokenKind
    text*: string        # surowy lexem
    line*, col*: int
    file*: string

  KeywordInfo* = object
    word*: string
    minStd*: CStd

## Słowa kluczowe wspólne dla C99+ (podzbiór startowy — do rozbudowy)
const BaseKeywords* = [
  "auto","break","case","char","const","continue","default","do",
  "double","else","enum","extern","float","for","goto","if","inline",
  "int","long","register","restrict","return","short","signed",
  "sizeof","static","struct","switch","typedef","union","unsigned",
  "void","volatile","while"
]

## Słowa kluczowe/konstrukcje wprowadzone w konkretnych standardach.
## minStd mówi, od której wersji dane słowo jest zarezerwowane jako keyword.
const VersionedKeywords* = [
  KeywordInfo(word: "_Bool", minStd: stdC99),
  KeywordInfo(word: "_Complex", minStd: stdC99),
  KeywordInfo(word: "_Imaginary", minStd: stdC99),

  KeywordInfo(word: "_Alignas", minStd: stdC11),
  KeywordInfo(word: "_Alignof", minStd: stdC11),
  KeywordInfo(word: "_Atomic", minStd: stdC11),
  KeywordInfo(word: "_Generic", minStd: stdC11),
  KeywordInfo(word: "_Noreturn", minStd: stdC11),
  KeywordInfo(word: "_Static_assert", minStd: stdC11),
  KeywordInfo(word: "_Thread_local", minStd: stdC11),

  # C23: nowe słowa kluczowe + ujednolicenie starych _Xxx -> xxx
  KeywordInfo(word: "alignas", minStd: stdC23),
  KeywordInfo(word: "alignof", minStd: stdC23),
  KeywordInfo(word: "bool", minStd: stdC23),
  KeywordInfo(word: "constexpr", minStd: stdC23),
  KeywordInfo(word: "false", minStd: stdC23),
  KeywordInfo(word: "nullptr", minStd: stdC23),
  KeywordInfo(word: "static_assert", minStd: stdC23),
  KeywordInfo(word: "thread_local", minStd: stdC23),
  KeywordInfo(word: "true", minStd: stdC23),
  KeywordInfo(word: "typeof", minStd: stdC23),
  KeywordInfo(word: "typeof_unqual", minStd: stdC23),
]

proc isKeywordFor*(word: string, std: CStd): bool =
  for k in BaseKeywords:
    if k == word: return true
  for k in VersionedKeywords:
    if k.word == word and std >= k.minStd:
      return true
  return false
