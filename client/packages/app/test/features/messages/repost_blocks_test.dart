// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/features/messages/providers/repost_blocks.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_data/data.dart';

import '../../support/fake_blocks.dart';

api.Message _wire(String id, {String? repostOf}) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'bot',
  authorDisplayName: 'starboard',
  seq: 1,
  content: 'starred',
  createdAt: 0,
  editedAt: null,
  repostOfAuthorId: repostOf,
);

Message _row(String id) => Message(
  id: id,
  channelId: 'c1',
  authorId: 'bot',
  seq: 1,
  content: 'starred',
  createdAt: 0,
  pending: false,
  failed: false,
);

ProviderContainer _container(Set<String> blocked) {
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      blocksProvider.overrideWith(
        (ref) => FixedBlocksController(ref, BlocksState(ids: blocked)),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test('a bot re-post of a blocked member is hidden, the rest stay', () {
    final container = _container({'carol'});
    container.read(messageExtrasProvider.notifier).applyMessages([
      _wire('m1', repostOf: 'carol'),
      _wire('m2', repostOf: 'dave'),
      _wire('m3'),
    ]);

    final hidden = container.read(blockedRepostIdsProvider).ids;
    final shown = visibleTranscript(
      [_row('m1'), _row('m2'), _row('m3')],
      container.read(blocksProvider).ids,
      hiddenReposts: hidden,
    ).messages.map((m) => m.id);

    expect(shown, ['m2', 'm3']);
  });

  test('with nobody blocked no re-post is hidden', () {
    final container = _container({});
    container
        .read(messageExtrasProvider.notifier)
        .applyMessage(_wire('m1', repostOf: 'carol'));

    expect(container.read(blockedRepostIdsProvider).ids, isEmpty);
  });

  test(
    'a blocked re-posted member silences the alert, search and pin filters',
    () {
      const blocks = BlocksState(ids: {'carol'});

      expect(blocks.hides(_wire('m1', repostOf: 'carol')), isTrue);
      expect(blocks.hides(_wire('m2', repostOf: 'dave')), isFalse);
      expect(blocks.hides(_wire('m3')), isFalse);
    },
  );
}
