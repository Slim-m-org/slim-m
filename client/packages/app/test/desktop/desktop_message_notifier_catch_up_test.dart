// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop alert path beyond a single live frame: one banner id per
/// conversation, a summary for what a reconnect's catch-up stored, and a
/// failing notification step that is logged rather than left uncaught.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import '../support/desktop_message_notifier_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  });

  Future<NotifierSetup> twoChannels() async {
    final setup = await wireNotifier();
    await MessageStore(setup.db).upsertChannels([
      const api.Channel(id: 'group-2', name: 'ops', kind: 'text', createdAt: 0),
      const api.Channel(id: 'dm-1', name: '', kind: 'dm', createdAt: 0),
    ]);
    return setup;
  }

  test('two channels get two banner ids and a burst keeps one', () async {
    if (!isDesktopHost) return;
    final setup = await twoChannels();
    for (final (id, channel) in [
      ('a', 'group-1'),
      ('b', 'group-2'),
      ('c', 'group-1'),
    ]) {
      setup.events.add(
        api.MessageCreated(
          notifierMessage(
            id: id,
            authorId: 'alice',
            channelId: channel,
            mentionsMe: true,
          ),
        ),
      );
    }
    await settleNotifier(
      setup,
      until: () => setup.notifications.ids.length == 3,
    );

    final ids = setup.notifications.ids;
    expect(ids.length, 3);
    expect(ids.toSet().length, 2);
    expect(ids.every((id) => id != null && id > 5), isTrue);
    await setup.dispose();
  });

  test('a mention stored by catch-up is announced once', () async {
    if (!isDesktopHost) return;
    final setup = await twoChannels();
    setup.caughtUp.add([
      notifierMessage(
        id: 'm1',
        authorId: 'alice',
        channelId: 'group-1',
        mentionsMe: true,
      ),
      notifierMessage(id: 'm2', authorId: 'alice', channelId: 'group-2'),
    ]);
    await settleNotifier(
      setup,
      until: () => setup.notifications.shown.isNotEmpty,
    );

    expect(setup.notifications.shown.length, 1);
    expect(setup.notifications.channels, [LocalAlertChannel.mentions]);
    await setup.dispose();
  });

  test('catch-up folds a conversation into one banner', () async {
    if (!isDesktopHost) return;
    final setup = await twoChannels();
    setup.caughtUp.add([
      notifierMessage(id: 'm1', authorId: 'alice', channelId: 'dm-1'),
      notifierMessage(id: 'm2', authorId: 'alice', channelId: 'dm-1'),
      notifierMessage(
        id: 'm3',
        authorId: 'bob',
        channelId: 'group-1',
        mentionsMe: true,
      ),
    ]);
    await settleNotifier(
      setup,
      until: () => setup.notifications.shown.length == 2,
    );

    expect(setup.notifications.shown.length, 2);
    expect(
      setup.notifications.shown.any((t) => t.contains('2 new messages')),
      isTrue,
    );
    await setup.dispose();
  });

  test('a notification that throws is logged, not unhandled', () async {
    if (!isDesktopHost) return;
    final setup = await twoChannels();
    setup.notifications.failWith = StateError('no notification daemon');
    setup.events.add(
      api.MessageCreated(
        notifierMessage(
          id: 'a',
          authorId: 'alice',
          channelId: 'group-1',
          mentionsMe: true,
        ),
      ),
    );
    await settleNotifier(setup);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(setup.notifications.shown, isEmpty);
    await setup.dispose();
  });
}
