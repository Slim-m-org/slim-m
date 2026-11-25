// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the account host shares across containers and tabs: the stored index,
/// the database file names, and the database a container has open.
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart' show CrossTab;
import 'package:slimm_platform/testing.dart';

import 'account_host_harness.dart';

const _a = 'https://first.example';
const _b = 'https://second.example';
const _c = 'https://third.example';

class _RecordingTabs implements CrossTab {
  final locks = <String>[];

  @override
  Future<T> exclusive<T>(String name, Future<T> Function() body) {
    locks.add(name);
    return body();
  }

  @override
  Future<bool> anotherTabIsOpen() async => false;

  @override
  Stream<void> get storageChanges => const Stream.empty();

  @override
  Future<String?> get tabId async => null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final harnesses = <AccountHarness>[];
  AccountHarness open(AccountHarness h) {
    harnesses.add(h);
    return h;
  }

  tearDown(() async {
    for (final h in harnesses) {
      await h.dispose();
    }
    harnesses.clear();
  });

  Future<void> addServer(AccountHarness h, String server) async {
    await h.host.beginAdd();
    h.host.active!.container
        .read(chosenServerProvider.notifier)
        .choose(Uri.parse(server));
    await pumpEventQueueTimes();
  }

  Future<List<String>> storedOrigins(AccountHarness h) async => [
    for (final account in (await h.store.load()).accounts) account.origin,
  ];

  group('the stored account index', () {
    test('two tabs that each add an account both keep it', () async {
      final keys = InMemoryKeyStore();
      final tabOne = open(AccountHarness(keys: keys));
      await tabOne.seed(_a, user: 'ann', active: true);
      await tabOne.boot();
      final tabTwo = open(AccountHarness(keys: keys));
      await tabTwo.boot();

      await addServer(tabOne, _b);
      await addServer(tabTwo, _c);

      expect(await storedOrigins(tabOne), containsAll([_a, _b, _c]));
    });

    test('every write runs under the cross-tab lock', () async {
      final tabs = _RecordingTabs();
      final h = open(AccountHarness(crossTab: tabs));
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();

      await addServer(h, _b);

      expect(tabs.locks, isNotEmpty);
      expect(tabs.locks.toSet(), {accountIndexLock});
    });
  });

  group('the database file of a new account', () {
    test('is never one another account already uses', () async {
      final names = ['slimm-taken.sqlite', 'slimm-taken.sqlite', 'slimm-new'];
      final h = open(
        AccountHarness(
          newDbFile: () => names.length > 1 ? names.removeAt(0) : names.single,
        ),
      );
      await h.seed(_a, user: 'ann', active: true);
      await h.boot();

      await addServer(h, _b);
      await h.host.beginAdd();
      h.host.active!.container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_c));
      await pumpEventQueueTimes();

      final files = [for (final r in h.host.accounts) r.account!.dbFile];
      expect(files.toSet(), hasLength(files.length));
      expect(files, contains('slimm-new'));
    });

    test('an existing account keeps its file name', () async {
      final h = open(AccountHarness());
      final seeded = await h.seed(_b, user: 'bea', active: true);
      await h.boot();

      expect((await h.store.load()).accounts.single.dbFile, seeded.dbFile);
      expect(h.host.active!.account!.dbFile, seeded.dbFile);
    });
  });

  group('the open database', () {
    test('reopens on the new file when the server changes', () async {
      final opened = <String>[];
      final h = open(
        AccountHarness(
          extraOverrides: [
            databaseProvider.overrideWith((ref) async {
              opened.add(ref.read(accountSlotProvider)!.databaseFile);
              final db = SlimmDatabase(NativeDatabase.memory());
              ref.onDispose(db.close);
              return db;
            }),
          ],
        ),
      );
      await h.seed(_a, active: true);
      await h.boot();
      final container = h.host.active!.container;
      final keep = container.listen(databaseProvider, (_, _) {});
      addTearDown(keep.close);
      await pumpEventQueueTimes();
      expect(opened, hasLength(1));

      container.read(chosenServerProvider.notifier).choose(Uri.parse(_b));
      await pumpEventQueueTimes();

      expect(opened, hasLength(2));
      expect(opened.last, container.read(accountSlotProvider)!.databaseFile);
      expect(opened.last, isNot(opened.first));
    });
  });
}
