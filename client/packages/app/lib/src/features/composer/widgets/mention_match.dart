// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How well a member answers what was typed after an `@`.
library;

import 'package:slimm_api/api.dart' as api;

const _from = 'àáâãäåāăąçćčďđèéêëēėęěğìíîïīįıłñńňòóôõöøōőřśşšșťțùúûüūůűųýÿźżž';
const _to = 'aaaaaaaaacccddeeeeeeeegiiiiiiilnnnooooooooorsssstttuuuuuuuuyyzzz';

final _fold = {
  for (var i = 0; i < _from.length; i++) _from[i]: _to[i],
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
int? mentionRank(String term, api.UserProfile member) {
  final needle = foldForMatch(term);
  if (needle.isEmpty) return 0;
  final user = foldForMatch(member.username);
  final name = foldForMatch(member.displayName);
  if (user == needle || name == needle) return 0;
  if (user.startsWith(needle) || name.startsWith(needle)) return 1;
  if (_wordStarts(name).any((w) => w.startsWith(needle)) ||
      _wordStarts(user).any((w) => w.startsWith(needle))) {
    return 2;
  }
  if (user.contains(needle) || name.contains(needle)) return 3;
  return null;
}

Iterable<String> _wordStarts(String text) {
  final words = text.split(RegExp(r'[\s._-]+'));
  return words.skip(1);
}
