// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A conversation's Android notification goes away once it is read; the
/// shared fallback ones only when nothing at all is unread.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/notification_read_sync.dart';
import 'package:slimm_app/src/push/android_push_messages.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  test('a read conversation loses its own notification only', () {
    final stale = staleNotificationIds(
      readChannelIds: {'chan-a'},
      unreadCount: 2,
    );
    expect(stale, {previewNotificationId('chan-a')});
    expect(stale, isNot(contains(previewNotificationId('chan-b'))));
  });

  test('the shared notifications stay while anything is unread', () {
    final stale = staleNotificationIds(
      readChannelIds: {'chan-a'},
      unreadCount: 1,
    );
    expect(stale, isNot(contains(LocalAlertChannel.messages.notificationId)));
    expect(stale, isNot(contains(LocalAlertChannel.mentions.notificationId)));
    expect(stale, isNot(contains(previewNotificationId(null))));
  });

  test('with nothing unread the shared notifications go too', () {
    final stale = staleNotificationIds(
      readChannelIds: {'chan-a'},
      unreadCount: 0,
    );
    expect(stale, contains(LocalAlertChannel.messages.notificationId));
    expect(stale, contains(LocalAlertChannel.mentions.notificationId));
    expect(stale, contains(previewNotificationId(null)));
  });

  test('an unloaded store never clears the shared notifications', () {
    expect(staleNotificationIds(readChannelIds: {}, unreadCount: 0), isEmpty);
  });
}
