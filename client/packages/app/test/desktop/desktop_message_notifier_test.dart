// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop live-message notifier turns an incoming socket message into an
/// OS notification, but only for someone else's message that arrives while the
/// window is not in the foreground. Own messages, a focused window, and a
/// channel the override quietens are each silent. The override half runs
/// through the real controller, and covers mentions-only as well as mute:
/// this path used to read only the mute, so a channel narrowed to mentions
/// still raised a banner for every ordinary message while the chime beside
/// it correctly stayed silent.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/accounts/providers/notification_target.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/desktop/providers/desktop_message_text_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import '../support/desktop_message_notifier_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a nickname names the author and the mention in the alert', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier(
      extra: [
        membersProvider.overrideWith(
          (ref) async => [
            const api.UserProfile(
              id: 'alice',
              username: 'alice',
              displayName: 'Captain Al',
              createdAt: 0,
            ),
            const api.UserProfile(
              id: 'bob',
              username: 'bob',
              displayName: 'Bob',
              createdAt: 0,
            ),
          ],
        ),
      ],
    );

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
          content: 'hi @alice',
        ),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, [
      'Captain Al in #general: hi @Captain Al',
    ]);
    await setup.dispose();
  });

  test('backgrounded, another author: shows a named notification', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
        ),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, ['Alice in #general: hi']);
    await setup.dispose();
  });

  test('the banner carries the server and channel it was posted for', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final slot = AccountSlot(
      account: Account.forServer(Uri.parse('https://second.example')),
      chooseServer: (_, _) => throw StateError('unused'),
    );
    final setup = await wireNotifier(
      extra: [accountSlotProvider.overrideWithValue(slot)],
    );

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    final target = NotificationTarget.decode(
      setup.notifications.payloads.single,
    )!;
    expect(
      (target.origin, target.channelId),
      ('https://second.example', 'group-1'),
    );
    await setup.dispose();
  });

  test('with message text off, only the author is named', () async {
    if (!isDesktopHost) return;
    SharedPreferences.setMockInitialValues({desktopMessageTextKey: false});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
          content: 'secret plans',
        ),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, ['New message from Alice']);
    await setup.dispose();
  });

  test('own message is never notified back to me', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'me', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test('after signing in as someone else, "me" is the new account', () async {
    // The account id used to be captured once at bootstrap and never again.
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();
    setup.container
        .read(sessionProvider)
        .set(
          const api.TokenPair(
            userId: 'someone-new',
            accessToken: 'access2',
            refreshToken: 'refresh2',
            accessExpiresAt: 0,
          ),
        );

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'someone-new',
          channelId: 'group-1',
        ),
      ),
    );
    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm2',
          authorId: 'me',
          authorDisplayName: 'Old Me',
          channelId: 'group-1',
        ),
      ),
    );
    await settleNotifier(setup);

    // Not exact: settleNotifier's flush is by the old "me", who may now notify too.
    expect(setup.notifications.shown, contains('Old Me in #general: hi'));
    expect(
      setup.notifications.shown.where((t) => t.contains('someone-new')),
      isEmpty,
      reason: 'the account signed in now must never be notified about itself',
    );
    await setup.dispose();
  });

  test('backgrounded, a message that notifies flashes the taskbar', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    expect(setup.taskbar.calls, ['flash']);
    await setup.dispose();
  });

  test('a focused window does not flash the taskbar', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final setup = await wireNotifier();
    setup.container.read(accountActiveProvider.notifier).state = false;

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isNotEmpty);
    expect(setup.taskbar.calls, isEmpty);
    await setup.dispose();
  });

  test('a focused window shows nothing', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final setup = await wireNotifier();

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test(
    'a focused window still notifies for a server that is not on screen',
    () async {
      if (!isDesktopHost) return;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final setup = await wireNotifier();
      setup.container.read(accountActiveProvider.notifier).state = false;

      setup.events.add(
        api.MessageCreated(
          notifierMessage(
            id: 'm1',
            authorId: 'alice',
            authorDisplayName: 'Alice',
            channelId: 'group-1',
          ),
        ),
      );
      await settleNotifier(setup);

      expect(setup.notifications.shown, ['Alice in #general: hi']);
      await setup.dispose();
    },
  );

  test('a muted channel stays silent', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mute('group-1');

    setup.events.add(
      api.MessageCreated(
        notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test(
    'a mentions-only channel stays silent for an ordinary message',
    () async {
      if (!isDesktopHost) return;
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      final setup = await wireNotifier();
      await setup.container
          .read(channelNotificationOverridesProvider.notifier)
          .mentionsOnly('group-1');

      setup.events.add(
        api.MessageCreated(
          notifierMessage(id: 'm1', authorId: 'alice', channelId: 'group-1'),
        ),
      );
      await settleNotifier(setup);

      expect(
        setup.notifications.shown,
        isEmpty,
        reason: 'the chime already refused this message; the banner did not',
      );
      await setup.dispose();
    },
  );

  test('a real mention in a mentions-only channel still notifies, as a '
      'mention', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();
    await setup.container
        .read(channelNotificationOverridesProvider.notifier)
        .mentionsOnly('group-1');

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'alice',
          authorDisplayName: 'Alice',
          channelId: 'group-1',
          content: 'hey @nick look',
          mentionsMe: true,
        ),
      ),
    );
    await settleNotifier(
      setup,
      until: () => setup.notifications.shown.isNotEmpty,
    );

    expect(setup.notifications.shown, ['Alice in #general: hey @nick look']);
    expect(
      setup.notifications.channels,
      [LocalAlertChannel.mentions],
      reason:
          'every banner used to be filed under messages, so the OS\'s '
          'own per-kind control for mentions never applied',
    );
    await setup.dispose();
  });

  test('a blocked author is never bannered', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();
    await setup.container.read(blocksProvider.notifier).block('pest');

    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'm1',
          authorId: 'pest',
          authorDisplayName: 'Pest',
          channelId: 'group-1',
        ),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });

  test('a message from a deleted account is not bannered', () async {
    if (!isDesktopHost) return;
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    final setup = await wireNotifier();

    setup.events.add(
      const api.MessageCreated(
        api.Message(
          id: 'm1',
          channelId: 'group-1',
          authorId: null,
          authorDisplayName: 'Deleted',
          seq: 1,
          content: 'hi',
          createdAt: 0,
          editedAt: null,
        ),
      ),
    );
    await settleNotifier(setup);

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });
}
