// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `Event::ThreadUpdated`'s client-side half: it is what makes a thread
/// appearing, or gaining a reply, visible to somebody already watching the
/// parent channel with nobody reloading. See `message_extras_thread_test.dart`
/// for the REST-merge half of the same cache.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('a live thread.updated frame makes a freshly opened thread appear '
      'with nobody reloading', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    expect(controller.extrasFor('m1').threadChannelId, isNull);

    events.add(
      const api.ThreadUpdated(
        channelId: 'c1',
        parentMessageId: 'm1',
        threadChannelId: 't1',
        replyCount: 0,
      ),
    );
    await _settle();

    final extras = controller.extrasFor('m1');
    expect(extras.threadChannelId, 't1');
    expect(
      extras.threadReplyCount,
      0,
      reason: 'a freshly opened, still-empty thread is a real 0',
    );
    expect(extras.threadLastReplyAt, isNull);
  });

  test(
    'a later frame with a higher count moves it live, without a fetch',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      events.add(
        const api.ThreadUpdated(
          channelId: 'c1',
          parentMessageId: 'm1',
          threadChannelId: 't1',
          replyCount: 0,
        ),
      );
      await _settle();

      events.add(
        const api.ThreadUpdated(
          channelId: 'c1',
          parentMessageId: 'm1',
          threadChannelId: 't1',
          replyCount: 1,
          lastReplyAt: 1700000000000,
        ),
      );
      await _settle();

      final extras = controller.extrasFor('m1');
      expect(extras.threadReplyCount, 1);
      expect(extras.threadLastReplyAt, 1700000000000);
    },
  );

  test(
    'a thread.updated frame never touches a message\'s cached reactions',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [liveEventsProvider.overrideWithValue(events.stream)],
      );
      addTearDown(container.dispose);
      final controller = container.read(messageExtrasProvider.notifier);

      controller.applyMessage(
        const api.Message(
          id: 'm1',
          channelId: 'c1',
          authorId: 'a1',
          authorDisplayName: 'Alice',
          seq: 1,
          content: 'hi',
          createdAt: 0,
          editedAt: null,
          reactions: [
            api.ReactionSummary(emoji: '\u{1F44D}', count: 1, reacted: false),
          ],
        ),
      );

      events.add(
        const api.ThreadUpdated(
          channelId: 'c1',
          parentMessageId: 'm1',
          threadChannelId: 't1',
          replyCount: 1,
        ),
      );
      await _settle();

      final extras = controller.extrasFor('m1');
      expect(extras.reactions, hasLength(1));
      expect(extras.threadReplyCount, 1);
    },
  );

  test('a thread.updated frame carries no per-viewer unread answer, so it '
      'leaves an already-known unread count untouched', () async {
    final events = StreamController<api.ServerEvent>.broadcast();
    addTearDown(events.close);
    final container = ProviderContainer(
      overrides: [liveEventsProvider.overrideWithValue(events.stream)],
    );
    addTearDown(container.dispose);
    final controller = container.read(messageExtrasProvider.notifier);

    controller.applyMessage(
      const api.Message(
        id: 'm1',
        channelId: 'c1',
        authorId: 'a1',
        authorDisplayName: 'Alice',
        seq: 1,
        content: 'hi',
        createdAt: 0,
        editedAt: null,
        threadChannelId: 't1',
        threadReplyCount: 1,
        threadUnreadCount: 5,
      ),
    );

    events.add(
      const api.ThreadUpdated(
        channelId: 'c1',
        parentMessageId: 'm1',
        threadChannelId: 't1',
        replyCount: 2,
      ),
    );
    await _settle();

    expect(
      controller.extrasFor('m1').threadUnreadCount,
      5,
      reason:
          'only a fresh REST fetch can answer unread; a live frame must '
          'not reset it to whatever it left the field at construction',
    );
  });
}
