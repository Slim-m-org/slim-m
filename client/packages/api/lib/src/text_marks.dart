// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Combining marks: how many may stack on one letter when drawn, and the
/// letters left once they are gone.
library;

/// Most combining marks drawn on one base character.
///
/// Every script people write in stacks three or fewer; a longer stack (the
/// "zalgo" look) only paints over the lines above and below it.
const kMaxMarksPerBase = 3;

/// Whether [c] is a combining mark of a block that stacks: Latin, Cyrillic,
/// Hebrew, Arabic, Thai and Lao marks, and the general-purpose blocks.
bool isStackingMark(int c) =>
    (c >= 0x0300 && c <= 0x036F) ||
    (c >= 0x0483 && c <= 0x0489) ||
    (c >= 0x0591 && c <= 0x05BD) ||
    c == 0x05BF ||
    c == 0x05C1 ||
    c == 0x05C2 ||
    c == 0x05C4 ||
    c == 0x05C5 ||
    c == 0x05C7 ||
    (c >= 0x0610 && c <= 0x061A) ||
    (c >= 0x064B && c <= 0x065F) ||
    c == 0x0670 ||
    (c >= 0x06D6 && c <= 0x06DC) ||
    (c >= 0x06DF && c <= 0x06E4) ||
    c == 0x06E7 ||
    c == 0x06E8 ||
    (c >= 0x06EA && c <= 0x06ED) ||
    c == 0x0E31 ||
    (c >= 0x0E34 && c <= 0x0E3A) ||
    (c >= 0x0E47 && c <= 0x0E4E) ||
    c == 0x0EB1 ||
    (c >= 0x0EB4 && c <= 0x0EBC) ||
    (c >= 0x0EC8 && c <= 0x0ECD) ||
    (c >= 0x1AB0 && c <= 0x1AFF) ||
    (c >= 0x1DC0 && c <= 0x1DFF) ||
    (c >= 0x20D0 && c <= 0x20FF) ||
    (c >= 0xFE20 && c <= 0xFE2F);

/// A variation selector neither starts a new letter nor stacks on one.
bool _isVariationSelector(int c) => c >= 0xFE00 && c <= 0xFE0F;

/// [text] with at most [max] [isStackingMark] marks kept on each base
/// character; [text] itself when nothing had to go.
String capCombiningMarks(String text, {int max = kMaxMarksPerBase}) {
  StringBuffer? out;
  var run = 0;
  var offset = 0;
  for (final c in text.runes) {
    final width = c > 0xFFFF ? 2 : 1;
    if (isStackingMark(c)) {
      run++;
    } else if (!_isVariationSelector(c)) {
      run = 0;
    }
    final drop = run > max;
    if (drop && out == null) out = StringBuffer(text.substring(0, offset));
    if (!drop) out?.writeCharCode(c);
    offset += width;
  }
  return out?.toString() ?? text;
}

/// [text] lower-cased with every [isStackingMark] mark removed, for matching
/// a name by its plain letters.
String foldMarks(String text) {
  final out = StringBuffer();
  for (final c in text.runes) {
    if (!isStackingMark(c)) out.writeCharCode(c);
  }
  return out.toString().toLowerCase();
}
