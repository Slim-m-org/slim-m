// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which seqs of a channel were fetched this session, kept beside the extras
/// they describe: a row with no attachments looks the same whether it has none
/// or was never fetched, so only the record of the fetches can tell them apart.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/hydrated_ranges.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/retention_sweep.dart';
import 'package:slimm_data/data.dart';

api.Message _message(String channelId, int seq) => api.Message(
  id: '$channelId-m$seq',
  channelId: channelId,
  authorId: 'user-1',
  authorDisplayName: 'User One',
  seq: seq,
  content: 'message $seq',
  createdAt: seq * 1000,
  editedAt: null,
);

List<api.Message> _page(String channelId, int from, int to) => [
  for (var seq = to; seq >= from; seq--) _message(channelId, seq),
];

void main() {
  group('HydratedRanges', () {
    test('before any fetch the gap is the newest end itself', () {
      expect(HydratedRanges().highestGap(1), HydratedRanges.newest);
    });

    test('the newest page leaves the gap right below it', () {
      final ranges = HydratedRanges()..add(251, HydratedRanges.newest);

      expect(ranges.highestGap(100), 250);
      expect(ranges.highestGap(251), isNull);
    });

    test('a page that does not reach the newest end leaves that gap open', () {
      final ranges = HydratedRanges()..add(100, 150);

      expect(ranges.highestGap(120), HydratedRanges.newest);
    });

    test('pages that touch or overlap merge into one', () {
      final ranges = HydratedRanges()
        ..add(251, HydratedRanges.newest)
        ..add(101, 150)
        ..add(151, 250);

      expect(ranges.highestGap(101), isNull);
      expect(ranges.highestGap(100), 100);
    });

    test('a hole between two pages is the highest gap, not the lowest', () {
      final ranges = HydratedRanges()
        ..add(401, HydratedRanges.newest)
        ..add(101, 200);

      expect(ranges.highestGap(101), 400);
      ranges.add(201, 400);
      expect(ranges.highestGap(101), isNull);
    });

    test('a page stated backwards records nothing', () {
      final ranges = HydratedRanges()..add(10, 5);

      expect(ranges.highestGap(1), HydratedRanges.newest);
    });
  });

  group('MessageExtrasController.applyPage', () {
    late ProviderContainer container;
    late MessageExtrasController extras;

    setUp(() {
      container = ProviderContainer();
      addTearDown(container.dispose);
      extras = container.read(messageExtrasProvider.notifier);
    });

    test('a full page covers down to its oldest row and no further', () {
      extras.applyPage('c1', _page('c1', 251, 300), before: null, limit: 50);

      expect(extras.highestUnhydrated('c1', 251), isNull);
      expect(extras.highestUnhydrated('c1', 250), 250);
    });

    test('a page below a cursor covers up to the row before it', () {
      extras
        ..applyPage('c1', _page('c1', 251, 300), before: null, limit: 50)
        ..applyPage('c1', _page('c1', 201, 250), before: 251, limit: 50);

      expect(extras.highestUnhydrated('c1', 201), isNull);
      expect(extras.highestUnhydrated('c1', 200), 200);
    });

    test('a short page means the channel starts there, so it covers all', () {
      extras.applyPage('c1', _page('c1', 1, 30), before: null, limit: 50);

      expect(extras.highestUnhydrated('c1', 1), isNull);
    });

    test('channels are recorded apart', () {
      extras.applyPage('c1', _page('c1', 251, 300), before: null, limit: 50);

      expect(extras.highestUnhydrated('c2', 251), HydratedRanges.newest);
    });

    test('a page also applies its messages', () {
      extras.applyPage('c1', _page('c1', 251, 300), before: null, limit: 50);

      expect(
        container.read(messageExtrasProvider).containsKey('c1-m300'),
        isTrue,
      );
    });

    test('clear forgets what was fetched along with the extras', () {
      extras
        ..applyPage('c1', _page('c1', 251, 300), before: null, limit: 50)
        ..clear();

      expect(extras.highestUnhydrated('c1', 251), HydratedRanges.newest);
    });

    test('a sweep forgets a closed channel but not an open one', () async {
      final db = SlimmDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final store = MessageStore(db);
      extras
        ..applyPage('open', _page('open', 251, 300), before: null, limit: 50)
        ..applyPage('shut', _page('shut', 251, 300), before: null, limit: 50);

      await runRetentionSweep(store, extras, {'open'});

      expect(extras.highestUnhydrated('open', 251), isNull);
      expect(
        extras.highestUnhydrated('shut', 251),
        HydratedRanges.newest,
        reason: 'its extras were dropped, so nothing was fetched any more',
      );
    });
  });
}
