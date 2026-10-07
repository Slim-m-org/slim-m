// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one name rule for channels and categories, mirroring the server's
/// `validate_channel_name` and `validate_category_name`.
library;

/// The server's ceiling, refused here rather than round-tripping first.
const int entityNameMaxChars = 64;

/// Unicode scalar values, as the server counts them; UTF-16 units would
/// double-count every emoji and refuse names the server accepts.
int entityNameLength(String raw) => raw.trim().runes.length;

bool entityNameValid(String raw) {
  final length = entityNameLength(raw);
  return length > 0 && length <= entityNameMaxChars;
}
