// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply in a thread the desktop holds no row for follows its parent channel's choices, and a focused window still announces one whose thread is not open, since no rail row lights for it.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/channels/providers/mounted_channels.dart';
import 'package:slimm_platform/platform.dart';
import '../support/desktop_message_notifier_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<NotifierSetup> wire({required bool focused}) async {
    binding.handleAppLifecycleStateChanged(
      focused ? AppLifecycleState.resumed : AppLifecycleState.inactive,
    );
    final setup = await wireNotifier();
    addTearDown(setup.dispose);
    return setup;
  }

  Future<void> reply(NotifierSetup setup, {bool mention = false}) async {
    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 't1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'thread-1',
          content: 'a reply',
          mentionsMe: mention,
        ),
      ),
    );
    await settleNotifier(setup);
  }

  test('an unfocused reply under a muted parent stays silent', () async {
    if (!isDesktopHost) return;
    final setup = await wire(focused: false);
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    await reply(setup, mention: true);

    expect(setup.notifications.shown, isEmpty);
  });

  test(
    'an unfocused reply under a mentions-only parent needs a mention',
    () async {
      if (!isDesktopHost) return;
      final setup = await wire(focused: false);
      await setup.container
          .read(channelNotificationOverridesProvider.notifier)
          .mentionsOnly('group-1');

      await reply(setup);
      expect(setup.notifications.shown, isEmpty);

      await reply(setup, mention: true);
      expect(setup.notifications.shown, ['Alice: a reply']);
    },
  );

  test('a focused window announces a reply whose thread is not open', () async {
    if (!isDesktopHost) return;
    final setup = await wire(focused: true);

    await reply(setup);

    expect(setup.notifications.shown, ['Alice: a reply']);
  });

  test('a focused window stays silent for the thread on screen', () async {
    if (!isDesktopHost) return;
    final setup = await wire(focused: true);
    setup.container.read(mountedChannelsProvider).register('thread-1');

    await reply(setup);

    expect(setup.notifications.shown, isEmpty);
  });

  test('a focused window stays silent for a muted parent', () async {
    if (!isDesktopHost) return;
    final setup = await wire(focused: true);
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    await reply(setup, mention: true);

    expect(setup.notifications.shown, isEmpty);
  });
}
