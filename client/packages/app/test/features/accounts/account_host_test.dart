// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One container per account: restore, switching and what stays apart.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

/// Reads fail for one handle until [unreadable] is cleared.
class _LockedKeys extends InMemoryKeyStore {
  final unreadable = <String>{};

  @override
  Future<String?> read(KeyHandle handle) {
    if (unreadable.contains(handle)) throw StateError('locked');
    return super.read(handle);
  }
}

api.Message _message(String id, int seq) => api.Message(
  id: id,
  channelId: 'c1',
  authorId: 'friend',
  authorDisplayName: 'friend',
  seq: seq,
  content: 'hello',
  createdAt: seq * 1000,
  editedAt: null,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  tearDown(() async => h.dispose());

  test('an upgrading install restores its one account signed in', () async {
    h = AccountHarness();
    await h.keys.put(serverUrlHandle, '$_a/');
    await h.keys.put(sessionTokenHandle, sessionJson('me'));

    await h.boot();

    final only = h.host.accounts.single;
    expect(only.account!.origin, _a);
    expect(only.signedIn, isTrue);
    expect(only.container.read(sessionProvider).tokens?.userId, 'me');
    expect(only.container.read(serverUrlProvider).toString(), '$_a/');
    expect(h.host.active, only);
  });

  test(
    'a fresh install has no account and a pending first container',
    () async {
      h = AccountHarness();
      await h.boot();

      expect(h.host.accounts, isEmpty);
      expect(h.host.active, isNotNull);
      expect(h.host.active!.container.read(chosenServerProvider), isNull);
    },
  );

  test('every stored account comes up, the active one on screen', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann');
    await h.seed(_b, user: 'bea', active: true);

    await h.boot();

    expect(h.host.accounts.map((r) => r.account!.origin).toSet(), {_a, _b});
    expect(h.host.active!.account!.origin, _b);
    for (final r in h.host.accounts) {
      expect(r.signedIn, isTrue);
    }
  });

  test('switching shows the other account and nothing of the first', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    final first = h.host.active!;
    final store = await first.container.read(storeProvider.future);
    await store.upsertChannels([
      const api.Channel(id: 'c1', name: 'general', kind: 'text', createdAt: 0),
    ]);
    await store.applyMessages([_message('m1', 1)]);

    await h.host.switchTo(_b);
    final second = h.host.active!;

    expect(second, isNot(first));
    expect(second.container.read(sessionProvider).tokens?.userId, 'bea');
    expect(second.container.read(serverUrlProvider).host, 'second.example');
    final other = await second.container.read(storeProvider.future);
    expect(await other.watchRailChannels().first, isEmpty);
    expect(first.container.read(sessionProvider).tokens?.userId, 'ann');
    expect(await store.watchRailChannels().first, hasLength(1));
  });

  test('each account keeps its own database file', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();
    for (final r in h.host.accounts) {
      await r.container.read(storeProvider.future);
    }

    final files = h.host.accounts.map((r) => r.slot.databaseFile).toSet();
    expect(files, hasLength(2));
    expect(files, contains(legacyDatabaseFile));
  });

  test('the index remembers which account was in front', () async {
    h = AccountHarness();
    await h.seed(_a, user: 'ann', active: true);
    await h.seed(_b, user: 'bea');
    await h.boot();

    await h.host.switchTo(_b);
    await pumpEventQueueTimes();

    expect((await h.store.load()).active?.origin, _b);
  });

  group('an unreadable session', () {
    test(
      'is kept, the account starts signed out, and activation retries',
      () async {
        final keys = _LockedKeys();
        h = AccountHarness(keys: keys);
        await h.seed(_a, user: 'ann', active: true);
        await h.seed(_b, user: 'bea');
        final b = (await h.store.load()).byOrigin(_b)!;
        keys.unreadable.add(b.sessionHandle);

        await h.boot();
        final runtime = h.host.runtimeFor(_b)!;
        expect(runtime.signedIn, isFalse);
        expect(runtime.slot.restoreFailed, isTrue);
        keys.unreadable.clear();
        expect(await h.store.readSession(b), sessionJson('bea'));

        await h.host.switchTo(_b);
        await pumpEventQueueTimes();

        expect(runtime.signedIn, isTrue);
        expect(runtime.container.read(sessionProvider).tokens?.userId, 'bea');
      },
    );

    test('corrupt session JSON is not deleted either', () async {
      h = AccountHarness();
      final a = await h.seed(_a, active: true);
      await h.keys.put(a.sessionHandle, '{broken');

      await h.boot();

      expect(h.host.accounts.single.signedIn, isFalse);
      expect(await h.keys.read(a.sessionHandle), '{broken');
    });
  });

  group('unread badges', () {
    test('count a background account live, and not the one in view', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
      final background = h.host.runtimeFor(_b)!;
      expect(background.unread.any, isFalse);

      final store = await background.container.read(storeProvider.future);
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
        const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
      ]);
      await store.applyMessages([_message('m1', 1)]);
      await pumpEventQueueTimes();

      expect(background.unread.channels, 1);
      expect(h.host.active!.unread.any, isFalse);
    });
  });

  group('a call across a switch', () {
    test('is reported for another account and cleared on returning', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
      expect(h.host.callElsewhere, isNull);

      h.host.runtimeFor(_a)!.container.read(testCallProvider.notifier).state =
          connectedCall;
      await pumpEventQueueTimes();
      expect(h.host.callElsewhere, isNull, reason: 'the call is on screen');

      await h.host.switchTo(_b);
      expect(h.host.callElsewhere?.account?.origin, _a);
      expect(
        h.host.runtimeFor(_a)!.container.read(testCallProvider),
        connectedCall,
      );

      await h.host.switchTo(_a);
      expect(h.host.callElsewhere, isNull);
    });
  });

  group('adding a server', () {
    test('mounts an empty container, files the server when chosen', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();

      await h.host.beginAdd();
      final pending = h.host.active!;
      expect(pending.account, isNull);
      expect(h.host.canCancelAdd, isTrue);

      pending.container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_b));
      await pumpEventQueueTimes();

      expect(pending.account?.origin, _b);
      expect(h.host.accounts, hasLength(2));
      expect((await h.store.load()).byOrigin(_b), isNotNull);
    });

    test('signing in stores the session under that server only', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();
      await h.host.beginAdd();
      final pending = h.host.active!;
      pending.container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_b));

      pending.container
          .read(sessionProvider)
          .set(
            const api.TokenPair(
              userId: 'bea',
              accessToken: 'x',
              refreshToken: 'y',
              accessExpiresAt: 0,
            ),
          );
      await pumpEventQueueTimes();

      final b = pending.account!;
      expect(await h.keys.read(b.sessionHandle), contains('"bea"'));
      expect(await h.keys.read(sessionTokenHandle), isNull);
      final a = h.host.runtimeFor(_a)!.account!;
      expect(await h.keys.read(a.sessionHandle), contains('ann'));
      expect(h.host.runtimeFor(_b)!.signedIn, isTrue);
    });

    test('cancelling drops a server that never signed in', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();
      await h.host.beginAdd();
      h.host.active!.container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_b));
      await pumpEventQueueTimes();

      await h.host.cancelAdd();
      await pumpEventQueueTimes();

      expect(h.host.active!.account!.origin, _a);
      expect(h.host.accounts, hasLength(1));
      expect((await h.store.load()).byOrigin(_b), isNull);
      expect(h.host.canCancelAdd, isFalse);
    });

    test('choosing a server already signed into lands on it', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.seed(_b, user: 'bea');
      await h.boot();
      await h.host.beginAdd();
      h.host.active!.container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_b));
      await pumpEventQueueTimes();

      expect(h.host.active!.account!.origin, _b);
      expect(h.host.active!.signedIn, isTrue);
      expect(h.host.accounts, hasLength(2));
    });
  });

  group('signing out and removing', () {
    test(
      'another account remaining removes this one and its session',
      () async {
        h = AccountHarness();
        final a = await h.seed(_a, user: 'ann', active: true);
        await h.seed(_b, user: 'bea');
        await h.boot();

        await h.host.signOut(_a);
        await pumpEventQueueTimes();

        expect(h.host.accounts.map((r) => r.account!.origin), [_b]);
        expect(h.host.active!.account!.origin, _b);
        expect(await h.keys.read(a.sessionHandle), isNull);
        expect((await h.store.load()).byOrigin(_a), isNull);
      },
    );

    test('the last account stays as a signed-out entry', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();

      await h.host.signOut(_a);
      await pumpEventQueueTimes();

      final only = h.host.accounts.single;
      expect(only.signedIn, isFalse);
      expect(only.account!.origin, _a);
    });
  });

  group('countUnread', () {
    test('a muted channel does not light the badge', () async {
      h = AccountHarness();
      await h.boot();
      final store = await h.host.active!.container.read(storeProvider.future);
      await store.upsertChannels([
        const api.Channel(
          id: 'c1',
          name: 'general',
          kind: 'text',
          createdAt: 0,
        ),
        const api.Channel(id: 'c2', name: 'random', kind: 'text', createdAt: 0),
      ]);
      await store.applyMessages([
        _message('m1', 1),
        const api.Message(
          id: 'm2',
          channelId: 'c2',
          authorId: 'friend',
          authorDisplayName: 'friend',
          seq: 1,
          content: 'hi',
          createdAt: 1000,
          editedAt: null,
        ),
      ]);
      final rows = await store.watchRailChannels().first;

      expect(
        countUnread(rows, const ChannelNotificationOverridesState()).channels,
        2,
      );
      const muted = ChannelNotificationOverridesState(
        byChannel: {'c1': api.NotificationPreference.nothing},
      );
      expect(countUnread(rows, muted).channels, 1);
    });
  });
}
