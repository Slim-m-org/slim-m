// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A tiny per-line lexer for a fenced code block's language label, mapping
/// source text to [AppCodeRole] spans for [AppCodeBlock] to colour.
///
/// Scoped deliberately: single-line comments and single-line strings only,
/// no multi-line block comments or triple-quoted strings, and no attempt at
/// full grammar. An unrecognised language renders unhighlighted rather than
/// guessing at one.
library;

import 'package:slimm_design_system/design_system.dart';

import 'message_code_langs.dart';

bool _isDigit(int code) => code >= 48 && code <= 57;
bool _isIdentStart(int code) =>
    (code >= 65 && code <= 90) || (code >= 97 && code <= 122) || code == 95;
bool _isIdentChar(int code) => _isIdentStart(code) || _isDigit(code);

const _punctuation = {
  '{',
  '}',
  '(',
  ')',
  '[',
  ']',
  '<',
  '>',
  ';',
  ',',
  '.',
  ':',
  '+',
  '-',
  '*',
  '/',
  '%',
  '=',
  '!',
  '&',
  '|',
  '^',
  '~',
  '?',
  '@',
};

List<AppCodeSpan> _lexLine(String line, LangSpec spec) {
  final spans = <AppCodeSpan>[];
  final n = line.length;
  var i = 0;

  void add(String text, AppCodeRole role) {
    if (text.isEmpty) return;
    if (spans.isNotEmpty && spans.last.role == role) {
      spans[spans.length - 1] = AppCodeSpan(spans.last.text + text, role);
    } else {
      spans.add(AppCodeSpan(text, role));
    }
  }

  bool matchesAt(String needle, int at) =>
      at + needle.length <= n &&
      line.substring(at, at + needle.length) == needle;

  while (i < n) {
    final c = line[i];

    final lineComment = spec.lineComment;
    if (lineComment != null && matchesAt(lineComment, i)) {
      add(line.substring(i), AppCodeRole.comment);
      break;
    }

    final block = spec.blockComment;
    if (block != null && matchesAt(block.$1, i)) {
      final end = line.indexOf(block.$2, i + block.$1.length);
      if (end == -1) {
        add(line.substring(i), AppCodeRole.comment);
        break;
      }
      final stop = end + block.$2.length;
      add(line.substring(i, stop), AppCodeRole.comment);
      i = stop;
      continue;
    }

    if (spec.stringChars.contains(c)) {
      var j = i + 1;
      while (j < n) {
        if (line[j] == r'\' && j + 1 < n) {
          j += 2;
          continue;
        }
        if (line[j] == c) {
          j++;
          break;
        }
        j++;
      }
      add(line.substring(i, j), AppCodeRole.string);
      i = j;
      continue;
    }

    if (_isDigit(c.codeUnitAt(0))) {
      var j = i;
      while (j < n && (_isDigit(line.codeUnitAt(j)) || line[j] == '_')) {
        j++;
      }
      if (j < n &&
          line[j] == '.' &&
          j + 1 < n &&
          _isDigit(line.codeUnitAt(j + 1))) {
        j++;
        while (j < n && (_isDigit(line.codeUnitAt(j)) || line[j] == '_')) {
          j++;
        }
      }
      while (j < n && _isIdentChar(line.codeUnitAt(j))) {
        j++;
      }
      add(line.substring(i, j), AppCodeRole.number);
      i = j;
      continue;
    }

    if (_isIdentStart(c.codeUnitAt(0))) {
      var j = i + 1;
      while (j < n && _isIdentChar(line.codeUnitAt(j))) {
        j++;
      }
      final word = line.substring(i, j);
      final key = spec.caseInsensitiveKeywords ? word.toUpperCase() : word;
      add(
        word,
        spec.keywords.contains(key) ? AppCodeRole.keyword : AppCodeRole.plain,
      );
      i = j;
      continue;
    }

    if (_punctuation.contains(c)) {
      add(c, AppCodeRole.punctuation);
      i++;
      continue;
    }

    add(c, AppCodeRole.plain);
    i++;
  }

  return spans.isEmpty ? const [AppCodeSpan('')] : spans;
}

/// Renders [code] (the text between a fence's markers) as classified lines
/// for [AppCodeBlock]. [language] is the raw fence token as authored; an
/// unrecognised one (or none) yields plain, unhighlighted lines.
List<AppCodeLine> lexCodeBlock(String code, String? language) {
  final spec = specForLanguage(language);
  final lines = code.split('\n');
  if (spec == null) {
    return [for (final line in lines) AppCodeLine.plain(line)];
  }
  return [for (final line in lines) AppCodeLine(_lexLine(line, spec))];
}
