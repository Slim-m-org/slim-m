// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Characters that change what a reader sees without changing what the text
/// does (trojan source, CVE-2021-42574): controls, text-direction marks and
/// ones that draw nothing.
library;

/// Mirrors `is_hidden_char` in the server's `hidden_chars.rs`; both are held to
/// `crates/slimm-server/tests/fixtures/hidden_chars.json`. The server refuses
/// text holding any of these (activity text, names, labels) rather than
/// trimming it, so a client that sends such text must clean it first.
bool isHiddenCharacter(int c) =>
    c < 0x20 ||
    (c >= 0x7F && c <= 0x9F) ||
    c == 0x00AD ||
    c == 0x034F ||
    c == 0x061C ||
    (c >= 0x115F && c <= 0x1160) ||
    (c >= 0x17B4 && c <= 0x17B5) ||
    c == 0x180E ||
    (c >= 0x200B && c <= 0x200F) ||
    (c >= 0x2028 && c <= 0x202E) ||
    (c >= 0x2060 && c <= 0x206F) ||
    c == 0x2800 ||
    c == 0x3164 ||
    c == 0xFEFF ||
    c == 0xFFA0 ||
    (c >= 0xFFF9 && c <= 0xFFFC) ||
    (c >= 0xE0000 && c <= 0xE007F);

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
