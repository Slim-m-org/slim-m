// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Per-language keyword tables and comment/string rules for
/// [message_code_lexer.dart]. Kept as space-separated word lists rather than
/// one-element-per-line set literals so a keyword table reads as a table,
/// not a few hundred lines of formatter output.
library;

Set<String> _words(String spaceSeparated) => spaceSeparated.split(' ').toSet();

final _dartKeywords = _words(
  'const final var void class extends implements with static return if '
  'else for while do switch case break continue new this super import '
  'export library part typedef enum mixin abstract async await yield try '
  'catch finally throw is as in null true false late required factory get '
  'set operator extension covariant dynamic int double String bool',
);

final _jsKeywords = _words(
  'const let var function return if else for while do switch case break '
  'continue new this class extends super import export default from as '
  'try catch finally throw typeof instanceof in of null undefined true '
  'false async await yield static get set',
);

final _tsKeywords = {
  ..._jsKeywords,
  ..._words(
    'interface type enum implements public private protected '
    'readonly namespace declare void',
  ),
};

final _pyKeywords = _words(
  'def return if elif else for while break continue pass class import '
  'from as try except finally raise with lambda yield global nonlocal '
  'assert del in is not and or None True False async await self',
);

final _rustKeywords = _words(
  'fn let mut const static return if else for while loop match break '
  'continue struct enum impl trait pub mod use crate self Self super as '
  'in where move ref unsafe async await dyn type true false None Some Ok '
  'Err',
);

final _goKeywords = _words(
  'func return if else for range switch case break continue package '
  'import var const type struct interface map chan go defer select '
  'fallthrough nil true false make new',
);

final _javaKeywords = _words(
  'public private protected static final class interface extends '
  'implements return if else for while do switch case break continue '
  'new this super try catch finally throw throws import package void int '
  'double float boolean long short byte char String null true false enum '
  'abstract',
);

final _cKeywords = _words(
  'int char float double void short long signed unsigned struct union '
  'enum typedef static const extern return if else for while do switch '
  'case break continue sizeof goto NULL',
);

final _cppKeywords = {
  ..._cKeywords,
  ..._words(
    'class public private protected virtual namespace using '
    'template typename new delete this try catch throw nullptr auto '
    'constexpr override',
  ),
};

final _csharpKeywords = _words(
  'class public private protected static namespace using new this try '
  'catch throw null true false var string bool int double float '
  'readonly override virtual interface enum async await return if else '
  'for while',
);

final _bashKeywords = _words(
  'if then else elif fi for while do done case '
  'esac function return break continue in echo export local readonly '
  'shift exit true false',
);

final _sqlKeywords = _words(
  'SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE '
  'ALTER DROP JOIN LEFT RIGHT INNER OUTER ON AND OR NOT NULL IS IN AS '
  'GROUP BY ORDER HAVING LIMIT DISTINCT UNION PRIMARY KEY FOREIGN '
  'REFERENCES DEFAULT',
);

/// One language's keyword set plus its comment and string syntax, enough
/// for [message_code_lexer.dart]'s single-line scanner to classify a line.
class LangSpec {
  const LangSpec({
    required this.keywords,
    this.lineComment,
    this.blockComment,
    this.stringChars = const {'"', "'"},
    this.caseInsensitiveKeywords = false,
  });

  final Set<String> keywords;
  final String? lineComment;

  /// (open, close). Matched within a single line only; an unclosed opener
  /// runs the comment to end of line rather than across a newline.
  final (String, String)? blockComment;
  final Set<String> stringChars;
  final bool caseInsensitiveKeywords;
}

LangSpec _cLikeSpec(Set<String> keywords) =>
    LangSpec(keywords: keywords, lineComment: '//', blockComment: ('/*', '*/'));

final Map<String, LangSpec> langSpecs = {
  'dart': _cLikeSpec(_dartKeywords),
  'javascript': _cLikeSpec(_jsKeywords),
  'typescript': _cLikeSpec(_tsKeywords),
  'python': LangSpec(keywords: _pyKeywords, lineComment: '#'),
  'rust': _cLikeSpec(_rustKeywords),
  'go': _cLikeSpec(_goKeywords),
  'java': _cLikeSpec(_javaKeywords),
  'c': _cLikeSpec(_cKeywords),
  'cpp': _cLikeSpec(_cppKeywords),
  'csharp': _cLikeSpec(_csharpKeywords),
  'bash': LangSpec(keywords: _bashKeywords, lineComment: '#'),
  'sql': LangSpec(
    keywords: _sqlKeywords,
    lineComment: '--',
    caseInsensitiveKeywords: true,
  ),
  'json': const LangSpec(
    keywords: {'true', 'false', 'null'},
    stringChars: {'"'},
  ),
  'yaml': const LangSpec(keywords: {}, lineComment: '#'),
};

/// Fence-language spellings this app is likely to actually see, mapped to
/// the canonical key above.
const Map<String, String> langAliases = {
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'py': 'python',
  'python3': 'python',
  'rs': 'rust',
  'golang': 'go',
  'sh': 'bash',
  'shell': 'bash',
  'zsh': 'bash',
  'c++': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'cs': 'csharp',
  'c#': 'csharp',
  'yml': 'yaml',
};

/// Resolves a raw fence language token (e.g. `js`, `PY`) to its [LangSpec],
/// or null when the language is unrecognised (or absent).
LangSpec? specForLanguage(String? language) {
  if (language == null) return null;
  final key = language.trim().toLowerCase();
  return langSpecs[langAliases[key] ?? key];
}
