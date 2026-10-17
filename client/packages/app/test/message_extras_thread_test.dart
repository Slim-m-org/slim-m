// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `MessageExtrasController`'s merge rule for a message's thread summary:
/// a REST fetch's real answer (including a genuine zero) is taken, and a
/// bare live frame that carries none of the three fields never clobbers
/// what a REST fetch already established.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

import 'channel_history_harness.dart';

api.Message _withThread(
  int seq, {
  String? threadChannelId,
  int? threadReplyCount,
  int? threadLastReplyAt,
  int? threadUnreadCount,
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
    threadChannelId: threadChannelId,
    threadReplyCount: threadReplyCount,
    threadLastReplyAt: threadLastReplyAt,
    threadUnreadCount: threadUnreadCount,
  );
}

void main() {
  test('a REST fetch carrying a thread is cached as-is, zero included', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(messageExtrasProvider.notifier)
        .applyMessage(
          _withThread(1, threadChannelId: 't1', threadReplyCount: 0),
        );

    final extras = container
        .read(messageExtrasProvider.notifier)
        .extrasFor('m1');
    expect(extras.threadChannelId, 't1');
    expect(
      extras.threadReplyCount,
      0,
      reason: 'a freshly opened, still-empty thread is a real 0, not absent',
    );
    expect(extras.threadLastReplyAt, isNull);
  });

  test('a bare live frame with no thread fields never erases an already-known '
      'thread summary', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    controller.applyMessage(
      _withThread(
        1,
        threadChannelId: 't1',
        threadReplyCount: 3,
        threadLastReplyAt: 1700000000000,
      ),
    );
    // What `Event::MessageEdited` sends: a bare DTO, no thread fields at all.
    controller.applyMessage(channelMessage(1));

    final extras = controller.extrasFor('m1');
    expect(
      extras.threadChannelId,
      't1',
      reason: 'an edit says nothing new about a thread and must not blank it',
    );
    expect(extras.threadReplyCount, 3);
    expect(extras.threadLastReplyAt, 1700000000000);
  });

  test('a later REST fetch updates the count to its fresher answer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    controller.applyMessage(
      _withThread(1, threadChannelId: 't1', threadReplyCount: 1),
    );
    controller.applyMessage(
      _withThread(
        1,
        threadChannelId: 't1',
        threadReplyCount: 2,
        threadLastReplyAt: 1700000000000,
      ),
    );

    final extras = controller.extrasFor('m1');
    expect(extras.threadReplyCount, 2);
    expect(extras.threadLastReplyAt, 1700000000000);
  });

  test('a REST fetch carrying an unread count is cached, zero included', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    container
        .read(messageExtrasProvider.notifier)
        .applyMessage(
          _withThread(
            1,
            threadChannelId: 't1',
            threadReplyCount: 3,
            threadUnreadCount: 0,
          ),
        );

    final extras = container
        .read(messageExtrasProvider.notifier)
        .extrasFor('m1');
    expect(
      extras.threadUnreadCount,
      0,
      reason: 'a fully-read thread is a real 0, not absent',
    );
  });

  test('a later REST fetch moves the unread count to its fresher answer', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    controller.applyMessage(
      _withThread(1, threadChannelId: 't1', threadUnreadCount: 3),
    );
    controller.applyMessage(
      _withThread(1, threadChannelId: 't1', threadUnreadCount: 1),
    );

    expect(controller.extrasFor('m1').threadUnreadCount, 1);
  });
}
