// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frame-parsing coverage for `ThreadUpdated`: the live signal that closes
/// the gap `docs/decisions/0005-threads.md` named - a thread appearing, or
/// gaining a reply, while a bystander already has the parent channel open.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('thread.updated decodes every field', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'thread.updated',
      'channel_id': 'c1',
      'parent_message_id': 'm1',
      'thread_channel_id': 't1',
      'reply_count': 3,
      'last_reply_at': 1700000000000,
    }));
    expect(event, isA<ThreadUpdated>());
    final thread = event! as ThreadUpdated;
    expect(thread.channelId, 'c1');
    expect(thread.parentMessageId, 'm1');
    expect(thread.threadChannelId, 't1');
    expect(thread.replyCount, 3);
    expect(thread.lastReplyAt, 1700000000000);
  });

  test('a freshly opened thread carries a null last_reply_at', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'thread.updated',
      'channel_id': 'c1',
      'parent_message_id': 'm1',
      'thread_channel_id': 't1',
      'reply_count': 0,
    }));
    expect((event! as ThreadUpdated).lastReplyAt, isNull);
  });

  test(
      'a thread.updated frame missing reply_count asks for a resync, not a crash',
      () {
    expect(
      ServerEvent.parse(jsonEncode({
        'type': 'thread.updated',
        'channel_id': 'c1',
        'parent_message_id': 'm1',
        'thread_channel_id': 't1',
      })),
      isA<ErrorEvent>(),
    );
  });
}
