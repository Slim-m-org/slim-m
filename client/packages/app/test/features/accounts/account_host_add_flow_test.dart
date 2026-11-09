// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What leaving the add flow by any route, or an account index that would not
/// read at launch, leaves behind in the stored list.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';

/// Reads fail for the chosen handles until [unreadable] is cleared.
class _LockedKeys extends InMemoryKeyStore {
  final unreadable = <String>{};

  @override
  Future<String?> read(KeyHandle handle) {
    if (unreadable.contains(handle)) throw StateError('locked');
    return super.read(handle);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AccountHarness h;
  tearDown(() async => h.dispose());

  Future<void> chooseInAddFlow(String server) async {
    h.host.active!.container
        .read(chosenServerProvider.notifier)
        .choose(Uri.parse(server));
    await pumpEventQueueTimes();
  }

  group('switching away while a server is being added', () {
    test('drops a server that never signed in, as cancelling does', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();
      await h.host.beginAdd();
      await chooseInAddFlow(_b);
      expect(h.host.accounts, hasLength(2));

      await h.host.switchTo(_a);
      await pumpEventQueueTimes();

      expect(h.host.active!.account!.origin, _a);
      expect(h.host.accounts, hasLength(1));
      expect(h.host.debugRuntimeCount, 1);
      expect((await h.store.load()).byOrigin(_b), isNull);
      expect(h.host.adding, isFalse);
    });

    test('retires the empty container of a flow with no server yet', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();
      await h.host.beginAdd();
      expect(h.host.debugRuntimeCount, 2);

      await h.host.switchTo(_a);
      await pumpEventQueueTimes();

      expect(h.host.debugRuntimeCount, 1);
      expect(h.host.active!.account!.origin, _a);
    });

    test('keeps a server that signed in before the switch', () async {
      h = AccountHarness();
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();
      await h.host.beginAdd();
      await chooseInAddFlow(_b);
      h.host.active!.container
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

      await h.host.switchTo(_a);
      await pumpEventQueueTimes();

      expect(h.host.accounts, hasLength(2));
      expect((await h.store.load()).byOrigin(_b), isNotNull);
    });

    test(
      'lands on a server already signed into without keeping a copy',
      () async {
        h = AccountHarness();
        await h.seed(_a, user: 'ann', active: true);
        await h.seed(_b, user: 'bea');
        await h.boot();
        await h.host.beginAdd();
        await chooseInAddFlow(_b);

        expect(h.host.active!.account!.origin, _b);
        expect(h.host.debugRuntimeCount, 2);
        expect(h.host.adding, isFalse);
      },
    );
  });

  group('an account index that would not read at launch', () {
    test('is read again and added to, never replaced', () async {
      final keys = _LockedKeys();
      h = AccountHarness(keys: keys);
      await h.seed(_a, user: 'ann', active: true);
      keys.unreadable.add(accountIndexHandle);
      await h.boot();
      expect(h.host.accounts, isEmpty);

      keys.unreadable.clear();
      await chooseInAddFlow(_b);

      final saved = await h.store.load();
      expect(saved.byOrigin(_a), isNotNull);
      expect(saved.byOrigin(_b), isNotNull);
    });

    test('is left alone while it still cannot be read', () async {
      final keys = _LockedKeys();
      h = AccountHarness(keys: keys);
      await h.seed(_a, user: 'ann', active: true);
      keys.unreadable.add(accountIndexHandle);
      await h.boot();

      await chooseInAddFlow(_b);
      keys.unreadable.clear();

      final saved = await h.store.load();
      expect(saved.byOrigin(_a), isNotNull);
      expect(saved.byOrigin(_b), isNull);
    });
  });
}
