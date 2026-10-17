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

List<AppCodeSpan> _lexLine(String line, LangSpec spec) =>
    _LineLexer(line, spec).lex();

/// Consumes [line] left to right; each `_take*` step claims a token at the
/// cursor and reports whether it did.
class _LineLexer {
  _LineLexer(this.line, this.spec);

  final String line;
  final LangSpec spec;
  final List<AppCodeSpan> _spans = [];
  int _i = 0;

  int get _n => line.length;

  List<AppCodeSpan> lex() {
    while (_i < _n) {
      if (_takeLineComment() ||
          _takeBlockComment() ||
          _takeString() ||
          _takeNumber() ||
          _takeWord()) {
        continue;
      }
      final c = line[_i];
      _add(
        c,
        _punctuation.contains(c) ? AppCodeRole.punctuation : AppCodeRole.plain,
      );
      _i++;
    }
    return _spans.isEmpty ? const [AppCodeSpan('')] : _spans;
  }

  void _add(String text, AppCodeRole role) {
    if (text.isEmpty) return;
    if (_spans.isNotEmpty && _spans.last.role == role) {
      _spans[_spans.length - 1] = AppCodeSpan(_spans.last.text + text, role);
    } else {
      _spans.add(AppCodeSpan(text, role));
    }
  }

  bool _matchesAt(String needle, int at) =>
      at + needle.length <= _n &&
      line.substring(at, at + needle.length) == needle;

  bool _takeLineComment() {
    final marker = spec.lineComment;
    if (marker == null || !_matchesAt(marker, _i)) return false;
    _add(line.substring(_i), AppCodeRole.comment);
    _i = _n;
    return true;
  }

  bool _takeBlockComment() {
    final block = spec.blockComment;
    if (block == null || !_matchesAt(block.$1, _i)) return false;
    final end = line.indexOf(block.$2, _i + block.$1.length);
    final stop = end == -1 ? _n : end + block.$2.length;
    _add(line.substring(_i, stop), AppCodeRole.comment);
    _i = stop;
    return true;
  }

  bool _takeString() {
    final quote = line[_i];
    if (!spec.stringChars.contains(quote)) return false;
    final stop = _stringEnd(quote);
    _add(line.substring(_i, stop), AppCodeRole.string);
    _i = stop;
    return true;
  }

  int _stringEnd(String quote) {
    var j = _i + 1;
    while (j < _n) {
      if (line[j] == r'\' && j + 1 < _n) {
        j += 2;
      } else if (line[j] == quote) {
        return j + 1;
      } else {
        j++;
      }
    }
    return j;
  }

  bool _takeNumber() {
    if (!_isDigit(line.codeUnitAt(_i))) return false;
    var j = _digitsEnd(_i);
    if (j + 1 < _n && line[j] == '.' && _isDigit(line.codeUnitAt(j + 1))) {
      j = _digitsEnd(j + 1);
    }
    while (j < _n && _isIdentChar(line.codeUnitAt(j))) {
      j++;
    }
    _add(line.substring(_i, j), AppCodeRole.number);
    _i = j;
    return true;
  }

  int _digitsEnd(int from) {
    var j = from;
    while (j < _n && (_isDigit(line.codeUnitAt(j)) || line[j] == '_')) {
      j++;
    }
    return j;
  }

  bool _takeWord() {
    if (!_isIdentStart(line.codeUnitAt(_i))) return false;
    var j = _i + 1;
    while (j < _n && _isIdentChar(line.codeUnitAt(j))) {
      j++;
    }
    final word = line.substring(_i, j);
    final key = spec.caseInsensitiveKeywords ? word.toUpperCase() : word;
    _add(
      word,
      spec.keywords.contains(key) ? AppCodeRole.keyword : AppCodeRole.plain,
    );
    _i = j;
    return true;
  }
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
