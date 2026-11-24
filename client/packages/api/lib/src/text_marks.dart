// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Combining marks: how many may stack on one letter when drawn, and the
/// letters left once they are gone.
library;

/// Most combining marks drawn on one base character.
///
/// Every script people write in stacks three or fewer; a longer stack (the
/// "zalgo" look) only paints over the lines above and below it.
const kMaxMarksPerBase = 3;

/// Whether [c] falls in any inclusive `(first, last)` pair of [ranges].
bool inCodeRanges(int c, List<(int, int)> ranges) {
  for (final (first, last) in ranges) {
    if (c >= first && c <= last) return true;
  }
  return false;
}

const _stackingRanges = <(int, int)>[
  (0x0300, 0x036F),
  (0x0483, 0x0489),
  (0x0591, 0x05BD),
  (0x05BF, 0x05BF),
  (0x05C1, 0x05C1),
  (0x05C2, 0x05C2),
  (0x05C4, 0x05C4),
  (0x05C5, 0x05C5),
  (0x05C7, 0x05C7),
  (0x0610, 0x061A),
  (0x064B, 0x065F),
  (0x0670, 0x0670),
  (0x06D6, 0x06DC),
  (0x06DF, 0x06E4),
  (0x06E7, 0x06E7),
  (0x06E8, 0x06E8),
  (0x06EA, 0x06ED),
  (0x0E31, 0x0E31),
  (0x0E34, 0x0E3A),
  (0x0E47, 0x0E4E),
  (0x0EB1, 0x0EB1),
  (0x0EB4, 0x0EBC),
  (0x0EC8, 0x0ECD),
  (0x1AB0, 0x1AFF),
  (0x1DC0, 0x1DFF),
  (0x20D0, 0x20FF),
  (0xFE20, 0xFE2F),
];

/// Whether [c] is a combining mark of a block that stacks: Latin, Cyrillic,
/// Hebrew, Arabic, Thai and Lao marks, and the general-purpose blocks.
bool isStackingMark(int c) => inCodeRanges(c, _stackingRanges);

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

/// [capCombiningMarks] for a name the server may leave out.
String? capOptionalMarks(String? text) =>
    text == null ? null : capCombiningMarks(text);

/// [text] lower-cased with every [isStackingMark] mark removed, for matching
/// a name by its plain letters.
String foldMarks(String text) {
  final out = StringBuffer();
  for (final c in text.runes) {
    if (!isStackingMark(c)) out.writeCharCode(c);
  }
  return out.toString().toLowerCase();
}
