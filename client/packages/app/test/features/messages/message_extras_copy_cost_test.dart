// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What `MessageExtrasController._set`'s whole-map copy actually costs.
///
/// The 2026-09-13 performance audit flagged it and deliberately did not fix it,
/// because the idiomatic update (`{...state, id: extras}`, which a StateNotifier
/// needs so listeners fire) is O(cache) and the cache is keyed by message id
/// across the whole session rather than per channel. Its instruction was to
/// measure before restructuring, and to close it with the number if the copy is
/// under a millisecond at realistic sizes.
///
/// This file held that measurement as two Stopwatch tests timing the bare map
/// spread, never `_set` itself, so they measured the Dart runtime rather than
/// guarding app code and cost about ten seconds a run. The numbers they
/// produced are kept below; re-measure with a throwaway Stopwatch loop over
/// `{...cache, id: entry}` if `channelWindowCeiling` ever changes.
///
/// **It is a dev-box number, which is a lower bound, not the phone measurement
/// the card asked for.** What it can settle is the shape: whether the cost is
/// microseconds, so a 10x device penalty still leaves it invisible, or already
/// milliseconds, so it is real wherever it runs.
///
/// ## What it measured, on this box, 2026-09-20
///
/// 100 entries: 9.5us. 1000: 8.1us. 5000: 43.0us. 20000: 648.6us.
///
/// Flat to about a thousand (fixed overhead dominates), then climbing, and
/// sharply so past five thousand.
///
/// ## Why that closes it rather than starting a restructure
///
/// The sizes that matter are the ones the cache can actually reach, and it is
/// bounded twice over: `retention_policy.dart`'s `channelWindowCeiling` caps the
/// store at 1000 rows **per channel**, and `retain()` then keeps only the entries
/// reachable from the channels actually open. So a realistic cache is about 1000
/// times the number of open channels - a few thousand entries - which is 8us to
/// 43us here. Even granting a phone 10x, that is under half a millisecond, or
/// roughly 3% of a 16.7ms frame.
///
/// The 649us figure needs twenty thousand entries, which is an order of magnitude
/// past what the ceiling permits and would need around twenty channels open and
/// fully paginated at once, with the ten-minute sweep never having run.
///
/// So the per-channel partition the audit sketched is not worth its cost: it
/// changes the key shape every consumer reads through, to save tens of
/// microseconds at sizes the retention ceiling already prevents. The number is
/// the answer, and the thing actually holding this up is the ceiling.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

/// One cache entry of the shape a real one has: a couple of reactions, which is
/// what most messages in a busy channel carry.
MessageExtras _entry(int i) => MessageExtras(
  reactions: [
    api.ReactionSummary(emoji: '\u{1F44D}', count: i % 7, reacted: i.isEven),
    api.ReactionSummary(emoji: '\u{1F389}', count: i % 3, reacted: false),
  ],
);

Map<String, MessageExtras> _cache(int size) => {
  for (var i = 0; i < size; i++) 'm$i': _entry(i),
};

void main() {
  test('a copy keeps every other entry, which is why it is a copy at all', () {
    final cache = _cache(50);
    const replaced = MessageExtras(
      reactions: [
        api.ReactionSummary(emoji: '\u{1F440}', count: 1, reacted: true),
      ],
    );

    final next = {...cache, 'm10': replaced};

    expect(next, hasLength(50));
    expect(next['m10']!.reactions.single.emoji, '\u{1F440}');
    expect(
      next['m11']!.reactions.first.emoji,
      cache['m11']!.reactions.first.emoji,
      reason: 'the untouched neighbours are the reason a StateNotifier copies',
    );
  });
}
