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
/// This is that measurement. What it measures is the map spread itself, written
/// out here rather than driven through `MessageExtrasController._set`, which is
/// private: so it is a number for the operation `_set` performs, not a guard on
/// `_set` continuing to perform it. If the controller ever stops being a flat
/// map copy, this file keeps reporting the spread's cost and will not notice.
/// Read it as "this is what the copy costs", not as a regression bound.
///
/// **It is a dev-box number, which is a lower bound, not the phone measurement
/// the card asked for.** What it can settle is the shape: whether the cost is
/// microseconds, so a 10x device penalty still leaves it invisible, or already
/// milliseconds, so it is real wherever it runs. The assertions are sized with
/// that 10x margin in mind rather than against this machine's own timings.
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
/// the answer, and the thing actually holding this up is the ceiling - which is
/// why the 20000 case stays below rather than being deleted. If anybody raises
/// `channelWindowCeiling`, this is where the cost of that shows up.
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

/// The copy `_set` performs, timed over enough iterations to be measurable.
({double perCopyUs, int copies}) _measure(int size, {int copies = 200}) {
  final cache = _cache(size);
  final entry = _entry(0);
  // Untimed warm-up: first-run allocation is not the thing being reported.
  final warm = {...cache, 'm0': entry};
  expect(warm, hasLength(size));

  final watch = Stopwatch()..start();
  for (var i = 0; i < copies; i++) {
    final next = {...cache, 'm0': entry};
    // Read it, so nothing can be optimised away as unused.
    expect(next.length, size);
  }
  watch.stop();
  return (perCopyUs: watch.elapsedMicroseconds / copies, copies: copies);
}

void main() {
  test('the whole-map copy cost, at the sizes the cache actually reaches', () {
    final results = <int, double>{};
    for (final size in [100, 1000, 5000, 20000]) {
      results[size] = _measure(size).perCopyUs;
    }

    // Printed, not just asserted: a passing test with no output is not a number.
    for (final entry in results.entries) {
      final perEvent = entry.value.toStringAsFixed(1);
      // ignore: avoid_print
      print('cache ${entry.key} entries: ${perEvent}us per live event');
    }

    expect(
      results[1000]!,
      lessThan(1000),
      reason:
          'a thousand entries is a busy session; a millisecond here would '
          'be a sixteenth of a frame on the dev box alone',
    );
  });

  test('the cost is linear in cache size, not worse', () {
    // Shape, not magnitude: superlinear would be a different problem entirely.
    final small = _measure(1000).perCopyUs;
    final large = _measure(10000).perCopyUs;

    expect(
      large / small,
      lessThan(40),
      reason:
          '10x the entries for roughly 10x the cost, with generous slack '
          'for allocator noise; far above that is superlinear',
    );
  });

  test('a copy keeps every other entry, which is why it is a copy at all', () {
    final cache = _cache(50);
    final replaced = MessageExtras(
      reactions: [
        const api.ReactionSummary(emoji: '\u{1F440}', count: 1, reacted: true),
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
