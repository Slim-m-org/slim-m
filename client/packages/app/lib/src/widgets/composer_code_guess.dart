// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Whether a pasted chunk reads as code, and which language. Deliberately
/// conservative: a false positive only costs an offer the reader ignores,
/// but prose or a list must never look like code.
library;

import 'dart:convert';

final RegExp _codeEnding = RegExp(r'[;{}()\[\]:,]\s*$|^\s*[})\]]');
final RegExp _indented = RegExp(r'^(\t| {2,})\S');
final RegExp _sqlStart = RegExp(
  r'^\s*(select|insert|update|delete|create|alter|drop|with|from|where|join|group by|order by)\b',
  caseSensitive: false,
);

/// The tag each language is recognised by, tried in order; the first whose
/// pattern matches anywhere in the chunk wins.
final List<(String, RegExp)> _languageSigns = [
  (
    'rust',
    RegExp(
      r'\bfn \w+\s*[(<]|\blet mut\b|\bimpl\b.*\{|::<|\bpub (fn|struct|enum)\b',
    ),
  ),
  (
    'go',
    RegExp(r'^package \w+|\bfunc (\(\w+ \*?\w+\) )?\w+\(|:= ', multiLine: true),
  ),
  (
    'python',
    RegExp(
      r'^\s*(def \w+\(.*\):|class \w+.*:|from \w[\w.]* import |import \w+$|if __name__)',
      multiLine: true,
    ),
  ),
  ('cpp', RegExp(r'#include\s*<\w+>|\bstd::|\btemplate\s*<')),
  ('c', RegExp(r'^#include\s*[<"]', multiLine: true)),
  ('java', RegExp(r'\bpublic (static )?(class|void)\b|System\.out\.')),
  ('csharp', RegExp(r'\busing System\b|\bnamespace \w+\s*\{|Console\.Write')),
  (
    'dart',
    RegExp(
      r"\bWidget build\(|\bvoid main\(\)|^import 'package:",
      multiLine: true,
    ),
  ),
  (
    'typescript',
    RegExp(r'\binterface \w+\s*\{|:\s*(string|number|boolean)\b|\btype \w+ ='),
  ),
  (
    'javascript',
    RegExp(r'\bfunction\b|\bconst \w+ =|=>|\bconsole\.\w+\(|\brequire\('),
  ),
  (
    'bash',
    RegExp(r'^\s*(\$ |sudo |echo |export \w+=|cd |if \[)', multiLine: true),
  ),
];

/// The language [text] most likely is, `''` when it reads as code of no
/// recognisable language, null when it does not read as code at all.
String? guessPastedCode(String text) {
  if (text.contains('```')) return null;
  final lines = text
      .split('\n')
      .where((l) => l.trim().isNotEmpty)
      .toList(growable: false);
  if (lines.length < 2) return null;

  final firstLine = lines.first.trim();
  if (firstLine.startsWith('#!')) {
    if (firstLine.contains('python')) return 'python';
    if (firstLine.contains('node')) return 'javascript';
    return 'bash';
  }
  if (_isJson(text)) return 'json';
  if (lines.where(_sqlStart.hasMatch).length * 2 >= lines.length &&
      _sqlStart.hasMatch(firstLine)) {
    return 'sql';
  }

  final endings = lines.where(_codeEnding.hasMatch).length / lines.length;
  final indented = lines.where(_indented.hasMatch).length / lines.length;
  final looksLikeCode = endings >= 0.5 || (indented >= 0.3 && endings >= 0.25);
  if (!looksLikeCode) return null;
  for (final (language, sign) in _languageSigns) {
    if (sign.hasMatch(text)) return language;
  }
  return '';
}

bool _isJson(String text) {
  final trimmed = text.trim();
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) return false;
  try {
    jsonDecode(trimmed);
    return true;
  } on FormatException {
    return false;
  }
}
