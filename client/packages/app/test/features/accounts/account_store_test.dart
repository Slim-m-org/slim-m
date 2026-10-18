// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The account index and the move from the single legacy session pair.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _session =
    '{"user_id":"u1","access_token":"a","refresh_token":"r","access_expires_at":0}';

/// Throws on a chosen handle, to stand for a keychain that cannot be read.
class _FlakyKeyStore extends InMemoryKeyStore {
  final unreadable = <String>{};
  final deleted = <String>[];

  @override
  Future<String?> read(KeyHandle handle) {
    if (unreadable.contains(handle)) throw StateError('locked');
    return super.read(handle);
  }

  @override
  Future<void> delete(KeyHandle handle) {
    deleted.add(handle);
    return super.delete(handle);
  }
}

void main() {
  group('origins', () {
    test('are scheme, host and port, lowercased', () {
      expect(
        originOf(Uri.parse('https://Slim.Example.com/app?x=1')),
        'https://slim.example.com',
      );
      expect(
        originOf(Uri.parse('http://10.0.0.5:8080/')),
        'http://10.0.0.5:8080',
      );
    });

    test('database files are stable and differ per origin', () {
      expect(
        databaseFileFor('https://a.example'),
        databaseFileFor('https://a.example'),
      );
      expect(
        databaseFileFor('https://a.example'),
        isNot(databaseFileFor('https://b.example')),
      );
      expect(databaseFileFor('https://a.example'), isNot(legacyDatabaseFile));
    });
  });

  group('fresh install', () {
    test('has no accounts and writes nothing', () async {
      final keys = InMemoryKeyStore();
      final index = await AccountStore(keys).loadOrMigrate();
      expect(index.accounts, isEmpty);
      expect(index.active, isNull);
      expect(await keys.read(accountIndexHandle), isNull);
    });

    test('a round trip keeps accounts and the active one', () async {
      final store = AccountStore(InMemoryKeyStore());
      final a = Account.forServer(Uri.parse('https://a.example'));
      final b = Account.forServer(Uri.parse('https://b.example:8443'));
      await store.save(AccountIndex(accounts: [a, b], activeOrigin: b.origin));
      final loaded = await store.load();
      expect(loaded.accounts.map((x) => x.origin), [a.origin, b.origin]);
      expect(loaded.active?.origin, b.origin);
      expect(loaded.accounts.last.serverUrl.port, 8443);
    });

    test('a corrupt index reads as empty and is never deleted', () async {
      final keys = _FlakyKeyStore();
      await keys.put(accountIndexHandle, '{not json');
      final index = await AccountStore(keys).load();
      expect(index.accounts, isEmpty);
      expect(keys.deleted, isEmpty);
    });
  });

  group('upgrading with a legacy session', () {
    test(
      'adopts the pair as one account and removes the legacy handles',
      () async {
        final keys = _FlakyKeyStore();
        await keys.put(serverUrlHandle, 'https://slim.example.com/');
        await keys.put(sessionTokenHandle, _session);

        final index = await AccountStore(keys).loadOrMigrate();

        final account = index.active!;
        expect(account.origin, 'https://slim.example.com');
        expect(account.dbFile, legacyDatabaseFile);
        expect(await keys.read(account.sessionHandle), _session);
        expect(await keys.read(sessionTokenHandle), isNull);
        expect(await keys.read(serverUrlHandle), isNull);
        expect((await AccountStore(keys).load()).accounts, hasLength(1));
      },
    );

    test(
      'a signed-out install keeps its server as a signed-out account',
      () async {
        final keys = InMemoryKeyStore();
        await keys.put(serverUrlHandle, 'https://slim.example.com');

        final store = AccountStore(keys);
        final index = await store.loadOrMigrate();

        expect(index.accounts, hasLength(1));
        expect(await store.readSession(index.accounts.single), isNull);
      },
    );

    test(
      'runs once: a second launch reads the index, not the legacy keys',
      () async {
        final keys = InMemoryKeyStore();
        await keys.put(serverUrlHandle, 'https://slim.example.com');
        await keys.put(sessionTokenHandle, _session);
        final store = AccountStore(keys);
        await store.loadOrMigrate();

        await keys.put(serverUrlHandle, 'https://other.example');
        final again = await store.loadOrMigrate();

        expect(again.accounts.single.origin, 'https://slim.example.com');
      },
    );

    test(
      'an interrupted migration leaves the legacy session in place',
      () async {
        final keys = _FlakyKeyStore();
        await keys.put(serverUrlHandle, 'https://slim.example.com');
        await keys.put(sessionTokenHandle, _session);
        keys.unreadable.add('session:https://slim.example.com');

        await AccountStore(keys).loadOrMigrate();

        expect(await keys.read(sessionTokenHandle), _session);
        expect(await keys.read(serverUrlHandle), 'https://slim.example.com');
      },
    );

    test('a legacy server url that is not a url migrates nothing', () async {
      final keys = InMemoryKeyStore();
      await keys.put(serverUrlHandle, 'not a url');
      await keys.put(sessionTokenHandle, _session);

      final index = await AccountStore(keys).loadOrMigrate();

      expect(index.accounts, isEmpty);
      expect(await keys.read(sessionTokenHandle), _session);
    });
  });
}
