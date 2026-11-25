// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How well a member answers what was typed after an `@`.
library;

import 'package:slimm_api/api.dart' as api;

const _accentGroups = {
  'a': 'àáâãäåāăą',
  'c': 'çćč',
  'd': 'ďđ',
  'e': 'èéêëēėęě',
  'g': 'ğ',
  'i': 'ìíîïīįı',
  'l': 'ł',
  'n': 'ñńň',
  'o': 'òóôõöøōő',
  'r': 'ř',
  's': 'śşšș',
  't': 'ťț',
  'u': 'ùúûüūůűų',
  'y': 'ýÿ',
  'z': 'źżž',
};

final _fold = {
  for (final MapEntry(key: ascii, value: accented) in _accentGroups.entries)
    for (final ch in accented.split('')) ch: ascii,
  'ß': 'ss',
  'æ': 'ae',
  'œ': 'oe',
};

/// Lowercased with accents removed, so `jose` finds `José`.
String foldForMatch(String text) {
  final out = StringBuffer();
  for (final ch in text.toLowerCase().split('')) {
    out.write(_fold[ch] ?? ch);
  }
  return out.toString();
}

/// Lower is better; null is no match. Exact, then prefix, then the start of a
/// later word in a multi-word name, then anywhere.
int? mentionRank(String term, api.UserProfile member) =>
    nameRank(term, [member.displayName, member.username]);

/// [mentionRank] over any set of names, so a role scores on the same scale
/// as a person.
int? nameRank(String term, List<String> names) {
  final needle = foldForMatch(term);
  if (needle.isEmpty) return 0;
  final folded = [for (final n in names) foldForMatch(n)];
  if (folded.any((n) => n == needle)) return 0;
  if (folded.any((n) => n.startsWith(needle))) return 1;
  if (folded.any((n) => _wordStarts(n).any((w) => w.startsWith(needle)))) {
    return 2;
  }
  if (folded.any((n) => n.contains(needle))) return 3;
  return null;
}

Iterable<String> _wordStarts(String text) {
  final words = text.split(RegExp(r'[\s._-]+'));
  return words.skip(1);
}
