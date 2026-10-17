// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The client half of custom emoji naming: what the server will make of what
/// someone typed, worked out before the upload rather than after it.
///
/// A mirror of `normalize_name` in `crates/slimm-server/src/emoji.rs`, and
/// deliberately a mirror rather than a guess: the upload sends the normalised
/// name, and normalising an already-normalised name is a no-op server-side
/// (its own `normalising_an_already_normalised_name_changes_nothing` test),
/// so what this shows is what gets stored. The uploader sees `party_parrot`
/// while typing "Party Parrot" instead of finding out afterwards.
library;

/// The longest name the server keeps, matching `MAX_NAME_LEN` in
/// `crates/slimm-server/src/emoji.rs`. Measured after normalising, as the
/// server measures it.
const int maxEmojiNameLength = 32;

const int _space = 0x20;
const int _hyphen = 0x2D;
const int _underscore = 0x5F;
const int _zero = 0x30;
const int _nine = 0x39;
const int _upperA = 0x41;
const int _upperZ = 0x5A;
const int _lowerA = 0x61;
const int _lowerZ = 0x7A;
const int _asciiCaseGap = _lowerA - _upperA;

/// Lowercases, turns spaces and hyphens into underscores, and drops
/// everything else. May return an empty string, which the server refuses.
///
/// Case folding is ASCII-only on purpose, matching the server's
/// `to_ascii_lowercase`: Dart's own `toLowerCase` folds `İ` to an `i`
/// plus a combining mark, which would survive here as `i` while the server
/// drops the character outright, and the two would then disagree.
String normalizeEmojiName(String raw) {
  final buffer = StringBuffer();
  for (final original in raw.trim().codeUnits) {
    var unit = original;
    if (unit >= _upperA && unit <= _upperZ) unit += _asciiCaseGap;
    if (unit == _space || unit == _hyphen) unit = _underscore;
    final keep =
        (unit >= _zero && unit <= _nine) ||
        (unit >= _lowerA && unit <= _lowerZ) ||
        unit == _underscore;
    if (keep) buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

/// Whether a name that has already been through [normalizeEmojiName] is one
/// the server will accept.
bool isUsableEmojiName(String normalized) =>
    normalized.isNotEmpty && normalized.length <= maxEmojiNameLength;

/// The Slack-convention shortcode for a normalised name. Built the way
/// `CustomEmoji.shortcode` builds it, since this one has to describe an emoji
/// that does not exist yet and so has no model to ask.
String emojiShortcode(String normalized) => ':$normalized:';
