// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rule every rail surface now reads, covered on its own axes rather than
/// once per widget: `channel_rail_unread_override_test.dart` pins that the
/// rows actually call it, this pins what it answers. Mirrors
/// `notification_sound_rules_test.dart`'s split for the chime's own gate.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/unread_indicator_rules.dart';

UnreadIndicator _for(
  api.NotificationPreference? override, {
  bool isDm = false,
  bool unread = true,
  bool mentioned = false,
  bool manuallyUnread = false,
}) => unreadIndicatorFor(
  channelOverride: override,
  isDm: isDm,
  unread: unread,
  mentioned: mentioned,
  manuallyUnread: manuallyUnread,
);

void main() {
  test('no override leaves both flags exactly as they came in', () {
    expect(_for(null), (unread: true, mentioned: false));
    expect(_for(null, mentioned: true), (unread: true, mentioned: true));
    expect(_for(null, unread: false), (
      unread: false,
      mentioned: false,
    ), reason: 'a read channel must not be lit by this rule either');
  });

  test('mentions-only shows nothing until a mention', () {
    expect(_for(api.NotificationPreference.mentions), (
      unread: false,
      mentioned: false,
    ));
    expect(_for(api.NotificationPreference.mentions, mentioned: true), (
      unread: false,
      mentioned: true,
    ), reason: 'the mention badge is the whole point of mentions-only');
  });

  test('a DM under mentions-only stays loud', () {
    expect(
      _for(api.NotificationPreference.mentions, isDm: true),
      (unread: true, mentioned: false),
      reason:
          'writing in a DM is addressing this account directly, the same '
          'reading narrow_for_notification_preference takes of it',
    );
  });

  test('mute shows nothing at all, a mention included', () {
    expect(_for(api.NotificationPreference.nothing, mentioned: true), (
      unread: false,
      mentioned: false,
    ));
    expect(_for(api.NotificationPreference.nothing, isDm: true), (
      unread: false,
      mentioned: false,
    ), reason: 'muting a DM silences it; only mentions-only spares one');
  });

  test('a hand-mark survives every override', () {
    for (final override in [
      null,
      api.NotificationPreference.mentions,
      api.NotificationPreference.nothing,
    ]) {
      expect(
        _for(override, unread: false, manuallyUnread: true).unread,
        isTrue,
        reason: 'asking to see $override unread is not a notification',
      );
    }
  });

  test('an everything override is read as no override', () {
    expect(
      _for(api.NotificationPreference.everything),
      _for(null),
      reason: 'the server refuses to store it, but a client must not guess',
    );
  });
}
