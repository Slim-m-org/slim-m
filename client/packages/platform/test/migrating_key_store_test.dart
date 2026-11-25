// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The iOS session store: first-unlock accessibility so a rotation while the
/// phone is locked is saved, and a one-time move of what an earlier build wrote
/// as WhenUnlocked.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

import 'fake_keychain.dart';

const _ios = HostPlatformKind(
  isWeb: false,
  isIOS: true,
  isAndroid: false,
  isMacOS: false,
  isWindows: false,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('the iOS session store configuration', () {
    test('it is first-unlock and device-bound, in the default group', () {
      final store = createPersistentKeyStore(platform: _ios);
      expect(store, isA<MigratingKeyStore>());
      final primary = (store as MigratingKeyStore).primary as SecureKeyStore;
      final options = primary.debugStorage.iOptions;
      expect(options.accessibility,
          KeychainAccessibility.first_unlock_this_device);
      expect(options.groupId, isNull);
    });

    test('the store it migrates from is the old WhenUnlocked one', () {
      final store = createPersistentKeyStore(platform: _ios);
      final legacy = (store as MigratingKeyStore).legacy as SecureKeyStore;
      expect(legacy.debugStorage.iOptions.accessibility,
          KeychainAccessibility.unlocked_this_device);
    });
  });

  group('MigratingKeyStore against the keychain rules', () {
    late FakeKeychain keychain;
    late MigratingKeyStore store;

    setUp(() {
      keychain = FakeKeychain();
      store = MigratingKeyStore(
        primary: keychain.view(Protection.afterFirstUnlock),
        legacy: keychain.view(Protection.whenUnlocked),
      );
    });

    test('a token rotation while the phone is locked is saved', () async {
      await store.put('session', 'token-1');
      keychain.locked = true;

      await store.put('session', 'token-2');

      keychain.locked = false;
      expect(await store.read('session'), 'token-2');
    });

    test('the old store loses the rotation, which is the bug it replaces',
        () async {
      final old = keychain.view(Protection.whenUnlocked);
      await old.put('session', 'token-1');
      keychain.locked = true;

      await expectLater(old.put('session', 'token-2'), throwsStateError);
    });

    test('an item an earlier build wrote is moved on first read', () async {
      await keychain.view(Protection.whenUnlocked).put('session', 'token-1');

      expect(await store.read('session'), 'token-1');

      expect(keychain.protectionOf('session'), Protection.afterFirstUnlock);
      keychain.locked = true;
      expect(await store.read('session'), 'token-1');
    });

    test('a write before the first read still lands on the new class',
        () async {
      await keychain.view(Protection.whenUnlocked).put('session', 'token-1');

      await store.put('session', 'token-2');

      expect(keychain.protectionOf('session'), Protection.afterFirstUnlock);
      expect(await store.read('session'), 'token-2');
    });

    test('a locked phone at upgrade is a read failure, not a sign-out',
        () async {
      await keychain.view(Protection.whenUnlocked).put('session', 'token-1');
      keychain.locked = true;

      await expectLater(store.read('session'), throwsStateError);

      keychain.locked = false;
      expect(await store.read('session'), 'token-1');
    });

    test('a missing secret reads as null and stays missing', () async {
      expect(await store.read('nothing'), isNull);
      expect(keychain.holds('nothing'), isFalse);
    });

    test('delete removes the secret whichever class holds it', () async {
      await keychain.view(Protection.whenUnlocked).put('old', 'a');
      await store.put('new', 'b');

      await store.delete('old');
      await store.delete('new');

      expect(keychain.holds('old'), isFalse);
      expect(keychain.holds('new'), isFalse);
    });

    test('clear removes everything', () async {
      await keychain.view(Protection.whenUnlocked).put('old', 'a');
      await store.put('new', 'b');

      await store.clear();

      expect(keychain.holds('old'), isFalse);
      expect(keychain.holds('new'), isFalse);
    });

    test('two stores reading the same item at once keep it', () async {
      await keychain.view(Protection.whenUnlocked).put('session', 'token-1');
      final other = MigratingKeyStore(
        primary: keychain.view(Protection.afterFirstUnlock),
        legacy: keychain.view(Protection.whenUnlocked),
      );

      final reads = await Future.wait([
        store.read('session'),
        other.read('session'),
      ]);

      expect(reads, ['token-1', 'token-1']);
      expect(await store.read('session'), 'token-1');
    });

    test('a failed move keeps the old copy and still answers the read',
        () async {
      await keychain.view(Protection.whenUnlocked).put('session', 'token-1');
      final failing = MigratingKeyStore(
        primary: _FailingPut(keychain.view(Protection.afterFirstUnlock)),
        legacy: keychain.view(Protection.whenUnlocked),
      );

      expect(await failing.read('session'), 'token-1');

      expect(keychain.protectionOf('session'), Protection.whenUnlocked);
    });
  });
}

class _FailingPut implements KeyStore {
  _FailingPut(this._inner);

  final KeyStore _inner;

  @override
  Future<KeyHandle> put(String name, String secret) =>
      throw StateError('write refused');

  @override
  Future<String?> read(KeyHandle handle) => _inner.read(handle);

  @override
  Future<void> delete(KeyHandle handle) => _inner.delete(handle);

  @override
  Future<void> clear() => _inner.clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      _inner.sign(handle, payload);
}
