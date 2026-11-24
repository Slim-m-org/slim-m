// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Characters that change what a reader sees without changing what the text
/// does (trojan source, CVE-2021-42574): controls, text-direction marks and
/// ones that draw nothing.
library;

import 'package:slimm_api/api.dart' show capCombiningMarks, inCodeRanges;

const _hiddenRanges = <(int, int)>[
  (0x00, 0x1F),
  (0x7F, 0x9F),
  (0x00AD, 0x00AD),
  (0x034F, 0x034F),
  (0x061C, 0x061C),
  (0x115F, 0x1160),
  (0x17B4, 0x17B5),
  (0x180E, 0x180E),
  (0x200B, 0x200F),
  (0x2028, 0x202E),
  (0x2060, 0x206F),
  (0x2800, 0x2800),
  (0x3164, 0x3164),
  (0xFEFF, 0xFEFF),
  (0xFFA0, 0xFFA0),
  (0xFFF0, 0xFFFC),
  (0x1BCA0, 0x1BCA3),
  (0x1D173, 0x1D17A),
  (0xE0000, 0xE00FF),
  (0xE01F0, 0xE0FFF),
];

/// Mirrors `is_hidden_char` in the server's `hidden_chars.rs`; both are held to
/// `crates/slimm-server/tests/fixtures/hidden_chars.json`. The server refuses
/// text holding any of these (activity text, names, labels) rather than
/// trimming it, so a client that sends such text must clean it first.
bool isHiddenCharacter(int c) => inCodeRanges(c, _hiddenRanges);

const _zwj = 0x200D;
const _tagFlagBase = 0x1F3F4;
const _tagEnd = 0xE007F;

bool _isTagLetter(int c) => c >= 0xE0020 && c <= 0xE007E;

/// Mirrors `is_pictographic` in the server's `hidden_chars.rs`, held to the same
/// fixture: the emoji a zero width joiner may sit between.
bool isPictographic(int c) =>
    c == 0x00A9 ||
    c == 0x00AE ||
    c == 0x203C ||
    c == 0x2049 ||
    c == 0x2122 ||
    c == 0x2139 ||
    (c >= 0x2190 && c <= 0x21FF) ||
    (c >= 0x2300 && c <= 0x23FF) ||
    c == 0x24C2 ||
    (c >= 0x25A0 && c <= 0x27BF) ||
    (c >= 0x2900 && c <= 0x297F) ||
    (c >= 0x2B00 && c <= 0x2BFF) ||
    c == 0x3030 ||
    c == 0x303D ||
    c == 0x3297 ||
    c == 0x3299 ||
    (c >= 0x1F000 && c <= 0x1FAFF);

/// The combining grapheme joiner: draws nothing, but stacked diacritics carry it between marks.
const _cgj = 0x034F;

/// Unicode White_Space, which Rust's `char::is_whitespace` tests on the server.
bool _isWhitespace(int c) =>
    (c >= 0x09 && c <= 0x0D) ||
    c == 0x20 ||
    c == 0x85 ||
    c == 0xA0 ||
    c == 0x1680 ||
    (c >= 0x2000 && c <= 0x200A) ||
    c == 0x2028 ||
    c == 0x2029 ||
    c == 0x202F ||
    c == 0x205F ||
    c == 0x3000;

/// Mirrors `hides_text_outside_emoji` in the server's `hidden_chars.rs`, held to
/// the fixture's case lists: a hidden character outside an emoji joiner
/// sequence, a subdivision flag, or a mark run ([_cgj] after something drawn).
bool hidesTextOutsideEmoji(String text) {
  final c = text.runes.toList();
  var afterDrawn = false;
  for (var i = 0; i < c.length; i++) {
    final continuesACluster = c[i] == _cgj && afterDrawn;
    afterDrawn =
        continuesACluster || !(_isWhitespace(c[i]) || isHiddenCharacter(c[i]));
    if (c[i] == _zwj) {
      final afterEmoji =
          i > 0 && (isPictographic(c[i - 1]) || c[i - 1] == 0xFE0F);
      final beforeEmoji = i + 1 < c.length && isPictographic(c[i + 1]);
      if (!afterEmoji || !beforeEmoji) return true;
    } else if (c[i] == _tagFlagBase) {
      var tags = 0;
      while (i + 1 + tags < c.length && _isTagLetter(c[i + 1 + tags])) {
        tags++;
      }
      final closed = i + 1 + tags < c.length && c[i + 1 + tags] == _tagEnd;
      if (tags > 0 && closed) i += tags + 1;
    } else if (isHiddenCharacter(c[i]) && !continuesACluster) {
      return true;
    }
  }
  return false;
}

/// What a profile field says when [hidesTextOutsideEmoji] refuses its text.
const hiddenCharactersRefusal =
    'Remove the invisible characters, then try again.';

/// Whether [c] is a hidden character a reader would have seen as a break
/// between words: a tab, a line or paragraph break, or a vertical tab or form
/// feed. [visibleText] keeps the break as a space instead of fusing the words.
bool _isHiddenBreak(int c) =>
    (c >= 0x09 && c <= 0x0D) || c == 0x85 || c == 0x2028 || c == 0x2029;

/// [text] with every hidden character removed, a break between words kept as a
/// single space, and the ends trimmed: text the server will accept as is.
String visibleText(String text) {
  final out = StringBuffer();
  for (final c in text.runes) {
    if (_isHiddenBreak(c)) {
      out.write(' ');
    } else if (!isHiddenCharacter(c)) {
      out.writeCharCode(c);
    }
  }
  return out.toString().replaceAll(RegExp(r' {2,}'), ' ').trim();
}

/// [text] without the bidi overrides U+202D and U+202E, which redraw the
/// letters around them in reverse (`evil\u202Etxt.exe` reads `evilexe.txt`).
/// The server strips them from what is sent now; this covers older messages.
/// Embeddings and isolates stay, since mixed-direction text relies on them.
String withoutBidiOverrides(String text) =>
    text.contains(_bidiOverride) ? text.replaceAll(_bidiOverride, '') : text;

final _bidiOverride = RegExp('[\u202D\u202E]');

/// [text] ready to draw as prose: well-formed, mark stacks capped, no bidi override.
String drawableText(String text) =>
    withoutBidiOverrides(capCombiningMarks(wellFormedUtf16(text)));

/// [text] with each unpaired UTF-16 surrogate replaced by U+FFFD, which is
/// what the web renderer draws anyway; the native one throws on it instead.
String wellFormedUtf16(String text) {
  StringBuffer? out;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    final paired =
        _isHighSurrogate(unit) &&
        i + 1 < text.length &&
        _isLowSurrogate(text.codeUnitAt(i + 1));
    if (paired) {
      out?.write(text.substring(i, i + 2));
      i++;
      continue;
    }
    final lone = _isHighSurrogate(unit) || _isLowSurrogate(unit);
    if (lone && out == null) out = StringBuffer(text.substring(0, i));
    out?.writeCharCode(lone ? 0xFFFD : unit);
  }
  return out?.toString() ?? text;
}

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;

bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;
