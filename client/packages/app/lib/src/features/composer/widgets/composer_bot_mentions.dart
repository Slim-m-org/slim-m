// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which bots the composer's own text currently `@mentions`, so a
/// mentioner-only help card can be offered once per bot. See
/// docs/decisions/0031-bot-command-registration.md.
library;

final _mentionPattern = RegExp(r'@([A-Za-z0-9_.-]+)');

/// The usernames [text] `@mentions` that are also in [botUsernames],
/// matched case-insensitively.
Set<String> mentionedBotUsernames(String text, Iterable<String> botUsernames) {
  final byLower = {for (final u in botUsernames) u.toLowerCase(): u};
  final found = <String>{};
  for (final match in _mentionPattern.allMatches(text)) {
    final username = byLower[match.group(1)!.toLowerCase()];
    if (username != null) found.add(username);
  }
  return found;
}
