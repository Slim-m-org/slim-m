// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The extras cache has two front doors with opposite authority, and getting
/// them the same way was the CQ3 bug.
///
/// A REST fetch is authoritative for reactions, so
/// [MessageExtrasController.applyMessages] lets an empty reaction list win - a
/// reaction removed back to zero comes back empty and has to actually clear. A
/// live `message.created`/`message.edited` frame omits reactions, so
/// [MessageExtrasController.applyMessage] must merge - the same empty list
/// there means "not carried", not "gone". The other fields merge on both
/// paths: they only ever gain, and merging keeps a slower page from nulling a
/// thread affordance a fresher frame already set.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import '../../channel_history_harness.dart';

api.Message _message(
  int seq, {
  List<api.ReactionSummary> reactions = const [],
  String? threadChannelId,
  int? threadReplyCount,
  bool mentionsMe = false,
}) {
  final base = channelMessage(seq);
  return api.Message(
    id: base.id,
    channelId: base.channelId,
    authorId: base.authorId,
    authorDisplayName: base.authorDisplayName,
    seq: base.seq,
    content: base.content,
    createdAt: base.createdAt,
    editedAt: null,
    reactions: reactions,
    threadChannelId: threadChannelId,
    threadReplyCount: threadReplyCount,
    mentionsMe: mentionsMe,
  );
}

const _thumb = api.ReactionSummary(emoji: 'thumb', count: 1, reacted: false);

void main() {
  test('a REST refetch reporting no reactions clears the stale tally', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);

    extras.applyMessages([
      _message(1, reactions: const [_thumb]),
    ]);
    expect(extras.extrasFor('m1').reactions, hasLength(1));

    // The reaction was removed server-side; the enriched list is now empty.
    extras.applyMessages([_message(1)]);

    expect(
      extras.extrasFor('m1').reactions,
      isEmpty,
      reason:
          'the fetch is authoritative, so an empty list means gone, not '
          'omitted - merging here would keep the stale tally forever (CQ3)',
    );
  });

  test('a stale REST refetch does not erase a thread affordance', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);

    // Known from an earlier fetch or a live ThreadUpdated that raced a page.
    extras.applyMessages([
      _message(1, threadChannelId: 't1', threadReplyCount: 2),
    ]);

    // That slower page, snapshotted before the thread existed, now lands.
    extras.applyMessages([_message(1)]);

    expect(
      extras.extrasFor('m1').threadChannelId,
      't1',
      reason:
          'a reply count only climbs and a thread is never removed, so a '
          'later fetch missing it cannot be more authoritative than what is '
          'already known - unlike reactions, which can genuinely reach zero',
    );
    expect(extras.extrasFor('m1').threadReplyCount, 2);
  });

  test('a live frame carrying no reactions keeps the known tally', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final extras = container.read(messageExtrasProvider.notifier);

    extras.applyMessages([
      _message(1, reactions: const [_thumb]),
    ]);

    // A bare `message.edited` frame omits reactions; it must not erase them.
    extras.applyMessage(_message(1));

    expect(
      extras.extrasFor('m1').reactions,
      hasLength(1),
      reason:
          'the live path merges, so an omitted field can only fail to add, '
          'never clobber what a REST fetch already established',
    );
  });

  test(
    'a refetch clears a mention an edit removed, a send response does not',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final extras = container.read(messageExtrasProvider.notifier);

      extras.applyMessages([_message(1, mentionsMe: true)]);
      extras.applyMessage(_message(1));
      expect(extras.extrasFor('m1').mentionsMe, isTrue);

      extras.applyMessages([_message(1)]);
      expect(extras.extrasFor('m1').mentionsMe, isFalse);
    },
  );
}
