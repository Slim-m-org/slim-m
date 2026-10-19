// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the desktop [KeyStore] backend: it must actually survive a
/// restart, which is the entire point of replacing [InMemoryKeyStore], and it
/// must actually be private, which is the entire point of not just reusing
/// ordinary preferences. Also covers the iOS keychain accessibility this app
/// configures, which flutter_secure_storage cannot itself verify without a
/// real keychain behind it.
library;

import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FileKeyStore', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('slimm_keystore_'));
    tearDown(() => dir.deleteSync(recursive: true));

    test('a stored secret is read back by handle', () async {
      final store = FileKeyStore(directory: dir);
      final handle = await store.put('session', 'super-secret');
      expect(await store.read(handle), 'super-secret');
    });

    test('a missing handle reads as null', () async {
      final store = FileKeyStore(directory: dir);
      expect(await store.read('nothing_here'), isNull);
    });

    test('delete removes only that secret', () async {
      final store = FileKeyStore(directory: dir);
      await store.put('a', 'first');
      await store.put('b', 'second');

      await store.delete('a');

      expect(await store.read('a'), isNull);
      expect(await store.read('b'), 'second');
    });

    test('clear removes everything this store wrote, and nothing else',
        () async {
      final store = FileKeyStore(directory: dir);
      await store.put('a', 'first');
      await store.put('b', 'second');

      await store.clear();

      expect(await store.read('a'), isNull);
      expect(await store.read('b'), isNull);
    });

    test('sign is unimplemented: no real key backend exists here', () async {
      final store = FileKeyStore(directory: dir);
      await expectLater(
        () => store.sign('handle', const [1, 2, 3]),
        throwsUnsupportedError,
      );
    });

    test('a secret survives a restart, across separate store instances',
        () async {
      // A real restart re-reads from disk; two independently constructed
      // stores pointed at the same directory play the same role here.
      final first = FileKeyStore(directory: dir);
      await first.put('session', 'token-value');

      final second = FileKeyStore(directory: dir);
      expect(await second.read('session'), 'token-value');
    });

    test('the push key survives a restart, across separate store instances',
        () async {
      final firstKeys =
          await DevicePushKeys(FileKeyStore(directory: dir)).publicKeyBase64();
      final secondKeys =
          await DevicePushKeys(FileKeyStore(directory: dir)).publicKeyBase64();

      expect(secondKeys, firstKeys);
    });

    test(
        'concurrent writes do not lose one another: every put lands, not '
        'just whichever read-modify-write cycle finished last', () async {
      final store = FileKeyStore(directory: dir);
      // Fired together, not awaited individually: the shape of a session write
      // and a push-key write landing on the same store back to back.
      await Future.wait([
        store.put('a', 'first'),
        store.put('b', 'second'),
        store.put('c', 'third'),
      ]);

      expect(await store.read('a'), 'first');
      expect(await store.read('b'), 'second');
      expect(await store.read('c'), 'third');
    });

    test(
        'a transient open failure does not disable storage for the rest of '
        'the process: the next call retries rather than replaying the same '
        'rejection', () async {
      // A file sits where the store's directory needs to be, so its first open fails.
      final blocker = Directory('${dir.path}/blocker');
      File(blocker.path).createSync();
      final store = FileKeyStore(directory: blocker);

      await expectLater(
        () => store.put('a', 'first'),
        throwsA(isA<FileSystemException>()),
      );

      // The environment recovers: a real directory now sits at that path.
      File(blocker.path).deleteSync();
      Directory(blocker.path).createSync();

      expect(await store.put('a', 'first'), 'a');
      expect(await store.read('a'), 'first');
    });

    test('the secrets file is restricted to this OS account', () async {
      final store = FileKeyStore(directory: dir);
      await store.put('session', 'super-secret');

      final file = File('${dir.path}/slimm_secrets.json');
      expect(file.existsSync(), isTrue);
      // Owner only, nothing for group or other. A file created with just the
      // process umask is typically group-readable, the exposure this closes.
      expect(file.statSync().modeString(), 'rw-------');
    }, testOn: 'linux');

    test('the directory is owner-only and no temp file is left behind',
        () async {
      final store = FileKeyStore(directory: dir);
      await store.put('session', 'super-secret');
      await store.put('session', 'rotated');

      expect(dir.statSync().modeString(), 'rwx------');
      expect(File('${dir.path}/slimm_secrets.json.tmp').existsSync(), isFalse);
    }, testOn: 'linux');

    test('a torn file reads as empty and the next write repairs it', () async {
      final store = FileKeyStore(directory: dir);
      await store.put('session', 'super-secret');
      File('${dir.path}/slimm_secrets.json')
          .writeAsStringSync('{"session": "su');

      expect(await store.read('session'), isNull);
      await store.put('session', 'fresh');

      expect(await store.read('session'), 'fresh');
    });
  });

  group('SecureKeyStore', () {
    test(
        'iOS items are device-bound: excluded from backup, and never '
        'migrate to a new device', () {
      final store = SecureKeyStore();
      expect(
        store.debugStorage.iOptions.accessibility,
        KeychainAccessibility.unlocked_this_device,
      );
    });

    test('sign is unimplemented: no real key backend exists here', () async {
      final store = SecureKeyStore();
      await expectLater(
        () => store.sign('handle', const [1, 2, 3]),
        throwsUnsupportedError,
      );
    });

    /// The session and refresh tokens must stay where they are. Relaxing this
    /// store instead of adding a second one would let anything running on a
    /// locked phone read a 30-day refresh token, which is a real downgrade
    /// and buys nothing: the extension has no use for that token.
    test(
        'the ordinary store is unchanged: no keychain group of its own, and '
        'unreadable until the owner has unlocked the phone', () {
      final options = SecureKeyStore().debugStorage.iOptions;
      expect(options.groupId, isNull);
      expect(options.accessibility, KeychainAccessibility.unlocked_this_device);
    });
  });

  /// The push key alone, because the Notification Service Extension reads it
  /// from a separate process while the phone is locked.
  group('SecureKeyStore.forPushKey', () {
    test(
        'it is in the group the extension claims, and not the app default '
        'group every other secret sits in', () {
      final options = SecureKeyStore.forPushKey().debugStorage.iOptions;
      expect(options.groupId, pushKeychainAccessGroup);
      expect(options.groupId, isNot('76S78SUWVM.top.npcserver.slimm'));
    });

    /// The point of the whole change. `WhenUnlocked` hands nothing over on a
    /// locked screen, which is the only screen a lock-screen preview is built
    /// for, so the extension would fall back to "New message" every time it
    /// mattered.
    test('it is readable once the phone has been unlocked since boot', () {
      expect(
        SecureKeyStore.forPushKey().debugStorage.iOptions.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
    });

    /// The backup guarantee is the other half of the attribute and is not
    /// what changed. `ThisDeviceOnly` is what excludes an item from iCloud
    /// and from local backups and stops it migrating to a new device, and
    /// both accessibilities this app uses carry it.
    test('it is still device-bound, so it rides into no backup', () {
      for (final accessibility in [
        SecureKeyStore().debugStorage.iOptions.accessibility,
        SecureKeyStore.forPushKey().debugStorage.iOptions.accessibility,
      ]) {
        expect(accessibility?.name, endsWith('_this_device'));
      }
    });

    /// A `deleteAll` on the ordinary store carries its own accessibility, so
    /// it cannot reach an item stored under a different one. That is what
    /// makes the migration's delete safe, and it stops being true the moment
    /// the two stores are configured alike.
    test(
        'the two stores differ in the attributes their queries carry, which '
        'is what keeps one from clearing the other', () {
      final session = SecureKeyStore().debugStorage.iOptions;
      final push = SecureKeyStore.forPushKey().debugStorage.iOptions;
      expect(
        push.accessibility != session.accessibility ||
            push.groupId != session.groupId,
        isTrue,
      );
    });

    test('sign is unimplemented here too', () async {
      await expectLater(
        () => SecureKeyStore.forPushKey().sign('handle', const [1, 2, 3]),
        throwsUnsupportedError,
      );
    });

    /// The factory is what the app actually calls, and it could hand back an
    /// ordinary store while every assertion above stayed true of a
    /// constructor nothing used.
    test('createPushKeyStore is this store, not the ordinary one', () {
      final options =
          (createPushKeyStore() as SecureKeyStore).debugStorage.iOptions;
      expect(options.groupId, pushKeychainAccessGroup);
      expect(
        options.accessibility,
        KeychainAccessibility.first_unlock_this_device,
      );
    });
  });

  group('createPersistentKeyStore', () {
    const platforms = {
      'web': HostPlatformKind(
        isWeb: true,
        isIOS: false,
        isAndroid: false,
        isMacOS: false,
        isWindows: false,
      ),
      'iOS': HostPlatformKind(
        isWeb: false,
        isIOS: true,
        isAndroid: false,
        isMacOS: false,
        isWindows: false,
      ),
      'Android': HostPlatformKind(
        isWeb: false,
        isIOS: false,
        isAndroid: true,
        isMacOS: false,
        isWindows: false,
      ),
      'macOS': HostPlatformKind(
        isWeb: false,
        isIOS: false,
        isAndroid: false,
        isMacOS: true,
        isWindows: false,
      ),
      'Windows': HostPlatformKind(
        isWeb: false,
        isIOS: false,
        isAndroid: false,
        isMacOS: false,
        isWindows: true,
      ),
    };

    for (final entry in platforms.entries) {
      test('${entry.key} gets the keychain backend', () {
        expect(
          createPersistentKeyStore(platform: entry.value),
          isA<SecureKeyStore>(),
        );
      });
    }

    test('Linux gets the file backend', () {
      const linux = HostPlatformKind(
        isWeb: false,
        isIOS: false,
        isAndroid: false,
        isMacOS: false,
        isWindows: false,
      );
      expect(createPersistentKeyStore(platform: linux), isA<FileKeyStore>());
    });
  });

  group('migrateLegacyFileSecrets', () {
    late Directory dir;

    setUp(() => dir = Directory.systemTemp.createTempSync('slimm_migrate_'));
    tearDown(() => dir.deleteSync(recursive: true));

    File legacyFile() => File('${dir.path}/slimm_secrets.json');

    test(
        'a populated legacy file lands in the new store, and the file is '
        'gone afterwards', () async {
      final legacy = FileKeyStore(directory: dir);
      await legacy.put('session_token_pair', 'token-value');
      await legacy.put('push_x25519_private_key', 'push-key-value');

      final destination = InMemoryKeyStore();
      await migrateLegacyFileSecrets(legacy: legacy, destination: destination);

      expect(await destination.read('session_token_pair'), 'token-value');
      expect(
        await destination.read('push_x25519_private_key'),
        'push-key-value',
      );
      expect(legacyFile().existsSync(), isFalse);
    });

    test('nothing to migrate when the legacy file never existed', () async {
      final legacy = FileKeyStore(directory: dir);
      final destination = InMemoryKeyStore();

      await migrateLegacyFileSecrets(legacy: legacy, destination: destination);

      expect(legacyFile().existsSync(), isFalse);
    });

    test(
        'a write failure on the new store leaves the legacy file in place, '
        'so a signed-in user is not stranded', () async {
      final legacy = FileKeyStore(directory: dir);
      await legacy.put('session_token_pair', 'token-value');

      await migrateLegacyFileSecrets(
        legacy: legacy,
        destination: _ThrowingKeyStore(),
      );

      expect(legacyFile().existsSync(), isTrue);
      expect(await legacy.read('session_token_pair'), 'token-value');
    });

    test(
        'migrateLegacyFileSecretsIfNeeded does nothing on a platform that '
        'never wrote the file - this suite runs on Linux', () async {
      await expectLater(migrateLegacyFileSecretsIfNeeded(), completes);
    }, testOn: 'linux');
  });
}

/// A store whose every write fails, standing in for a keychain that refuses
/// this one write - a locked session, a full disk, whatever the reason.
class _ThrowingKeyStore implements KeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) async =>
      throw StateError('keychain unavailable');

  @override
  Future<String?> read(KeyHandle handle) async =>
      throw StateError('keychain unavailable');

  @override
  Future<void> delete(KeyHandle handle) async =>
      throw StateError('keychain unavailable');

  @override
  Future<void> clear() async => throw StateError('keychain unavailable');

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) async =>
      throw StateError('keychain unavailable');
}
