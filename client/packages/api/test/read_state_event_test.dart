// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `read_state.changed`: this account's read marker
/// moved on another device.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed read_state.changed frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'read_state.changed',
        'channel_id': 'c1',
        'last_read_seq': 7,
      }),
    );
    expect(event, isA<ReadStateChanged>());
    expect((event as ReadStateChanged).channelId, 'c1');
    expect(event.lastReadSeq, 7);
  });

  test('a frame missing last_read_seq is ignored, not thrown', () {
    final event = ServerEvent.parse(
      jsonEncode({'type': 'read_state.changed', 'channel_id': 'c1'}),
    );
    expect(event, isNull);
  });

  test('carries the manual unread flag, false when an older server omits it',
      () {
    final marked = ServerEvent.parse(
      jsonEncode({
        'type': 'read_state.changed',
        'channel_id': 'c1',
        'last_read_seq': 7,
        'manually_unread': true,
      }),
    );
    expect((marked as ReadStateChanged).manuallyUnread, isTrue);
    final legacy = ServerEvent.parse(
      jsonEncode({
        'type': 'read_state.changed',
        'channel_id': 'c1',
        'last_read_seq': 7,
      }),
    );
    expect((legacy as ReadStateChanged).manuallyUnread, isFalse);
  });

  test('parses notification_override.changed, null meaning cleared', () {
    final set = ServerEvent.parse(
      jsonEncode({
        'type': 'notification_override.changed',
        'channel_id': 'c1',
        'preference': 'mentions',
      }),
    );
    expect(set, isA<NotificationOverrideChanged>());
    expect(
      (set as NotificationOverrideChanged).preference,
      NotificationPreference.mentions,
    );
    final cleared = ServerEvent.parse(
      jsonEncode({
        'type': 'notification_override.changed',
        'channel_id': 'c1',
        'preference': null,
      }),
    );
    expect((cleared as NotificationOverrideChanged).preference, isNull);
  });

  test('parses blocks.changed', () {
    expect(
      ServerEvent.parse(jsonEncode({'type': 'blocks.changed'})),
      isA<BlocksChanged>(),
    );
  });

  test('parses category_mute.changed', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'category_mute.changed',
        'category_id': 'k1',
        'muted': true,
      }),
    );
    expect(event, isA<CategoryMuteChanged>());
    expect((event as CategoryMuteChanged).categoryId, 'k1');
    expect(event.muted, isTrue);
  });
}
