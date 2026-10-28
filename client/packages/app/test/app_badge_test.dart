// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iPhone icon badge: which channels count, which are read, and what the
/// app tells the native side.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/app_badge_sync.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart' show Channel;

Channel _channel(String id, {int cursor = 0, int read = 0, int mention = 0}) =>
    Channel(
      id: id,
      name: id,
      kind: 'text',
      createdAt: 0,
      position: 0,
      cursor: cursor,
      lastReadSeq: read,
      mentionedSeq: mention,
      slowModeSeconds: 0,
      joinMuted: false,
      isPersonalSpace: false,
    );

void main() {
  const none = ChannelNotificationOverridesState();

  test('a muted channel is neither counted nor listed as unread', () {
    final channels = [_channel('a', cursor: 5), _channel('muted', cursor: 5)];
    const muted = ChannelNotificationOverridesState(
      byChannel: {'muted': api.NotificationPreference.nothing},
    );
    expect(countUnread(channels, muted).channels, 1);
    expect(readChannelIds(channels, muted), {'muted'});
  });

  test('a channel that is caught up is read', () {
    final channels = [
      _channel('a', cursor: 5, read: 5),
      _channel('b', cursor: 2),
    ];
    expect(readChannelIds(channels, none), {'a'});
  });

  test('a mention counts in a mentions-only channel', () {
    final channels = [_channel('m', cursor: 4, mention: 4)];
    const mentionsOnly = ChannelNotificationOverridesState(
      byChannel: {'m': api.NotificationPreference.mentions},
    );
    expect(countUnread(channels, mentionsOnly).channels, 1);
    expect(readChannelIds(channels, mentionsOnly), isEmpty);
  });

  test('the badge sums unread channels across accounts', () {
    expect(
      appBadgeCount(const [
        AccountUnread(channels: 2),
        AccountUnread(channels: 3, mentions: 1),
      ]),
      5,
    );
  });
}
