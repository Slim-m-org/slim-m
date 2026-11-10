// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one Dart comment and string scrubber every source-reading gate shares.
///
/// A regex or brace count over raw source is fooled by a comment or a string
/// that happens to hold the shape it searches for, so a gate reads the text
/// through [codeOnly] (or [stripComments] when a string's own text is the
/// point). Both keep every character's index and every line break, so offsets
/// and line numbers computed on the result hold for the original.
///
/// It lexes the same way `scripts/lib/dart_source.py` does: raw strings, triple
/// quotes and `${...}` interpolation are understood, and a single-line string
/// ends at its line break, so one mis-lexed quote cannot swallow the file.
library;

/// [source] with `//` and `/* */` comments and the content of every string
/// literal, delimiters included, blanked to spaces.
///
/// The code inside a `${...}` interpolation is kept, since it is real code.
String codeOnly(String source) => _Scrubber(source, blankStrings: true).run();

/// [source] with only the comments blanked, every string literal left as it was.
String stripComments(String source) =>
    _Scrubber(source, blankStrings: false).run();

class _Scrubber {
  _Scrubber(this._text, {required this.blankStrings});

  final String _text;
  final bool blankStrings;
  final _out = StringBuffer();
  var _i = 0;

  String run() {
    _scan(inInterpolation: false);
    return _out.toString();
  }

  /// Copies code from the cursor until the end, or past the `}` that closes
  /// the interpolation being scanned.
  void _scan({required bool inInterpolation}) {
    var depth = 0;
    while (_i < _text.length) {
      final c = _text[_i];
      if (c == "'" || c == '"') {
        _copyString(raw: _opensRawString(_i));
      } else if (_text.startsWith('//', _i)) {
        _blankUntil(_endOfLine());
      } else if (_text.startsWith('/*', _i)) {
        _blankUntil(_endOfBlockComment());
      } else if (inInterpolation && c == '}' && depth == 0) {
        _out.write(c);
        _i++;
        return;
      } else {
        if (inInterpolation && (c == '{' || c == '}')) {
          depth += c == '{' ? 1 : -1;
        }
        _out.write(c);
        _i++;
      }
    }
  }

  /// True when the quote at [quoteAt] opens a raw string, `r'...'`, whose
  /// backslash is literal, so `r'\'` closes at its second quote.
  bool _opensRawString(int quoteAt) {
    if (quoteAt == 0 || _text[quoteAt - 1] != 'r') return false;
    if (quoteAt < 2) return true;
    final before = _text.codeUnitAt(quoteAt - 2);
    return !_isIdentifierUnit(before);
  }

  bool _isIdentifierUnit(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x5a) ||
      (unit >= 0x61 && unit <= 0x7a) ||
      unit == 0x5f ||
      unit == 0x24;

  void _copyString({required bool raw}) {
    final quote = _text[_i];
    final delimiter = _text.startsWith(quote * 3, _i) ? quote * 3 : quote;
    _writeString(delimiter);
    _i += delimiter.length;
    while (_i < _text.length) {
      if (_text.startsWith(delimiter, _i)) {
        _writeString(delimiter);
        _i += delimiter.length;
        return;
      }
      final c = _text[_i];
      if (c == '\n' && delimiter.length == 1) return;
      if (c == r'\' && !raw && _i + 1 < _text.length) {
        _writeString(_text.substring(_i, _i + 2));
        _i += 2;
      } else if (c == r'$' && !raw && _text.startsWith('{', _i + 1)) {
        _out.write(r'${');
        _i += 2;
        _scan(inInterpolation: true);
      } else {
        _writeString(c);
        _i++;
      }
    }
  }

  void _writeString(String chars) =>
      _out.write(blankStrings ? _blanked(chars) : chars);

  void _blankUntil(int stop) {
    _out.write(_blanked(_text.substring(_i, stop)));
    _i = stop;
  }

  int _endOfLine() {
    final end = _text.indexOf('\n', _i);
    return end == -1 ? _text.length : end;
  }

  int _endOfBlockComment() {
    final end = _text.indexOf('*/', _i + 2);
    return end == -1 ? _text.length : end + 2;
  }

  static String _blanked(String chars) {
    final out = StringBuffer();
    for (final unit in chars.codeUnits) {
      out.writeCharCode(unit == 0x0a || unit == 0x0d ? unit : 0x20);
    }
    return out.toString();
  }
}
