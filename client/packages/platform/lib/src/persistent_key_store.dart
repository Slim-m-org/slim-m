// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Persistent [KeyStore] backends: the platform keychain everywhere it is
/// always present, and an owner-only file on Linux, where a Secret Service
/// agent often is not running. Web obfuscates rather than protects. The
/// tradeoff is in docs/internals.md.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'host_platform.dart';
import 'key_store.dart';

/// The keychain group the push private key lives in, shared with the
/// Notification Service Extension so it can open a sealed push envelope while
/// the app itself is not running.
///
/// Deliberately its own group rather than the app's default one
/// (`76S78SUWVM.top.npcserver.slimm`, which is where every other secret this
/// app stores still sits): the extension is a separate binary, and a group
/// holding only the push key is one it can be given without also handing it
/// the refresh token. Both binaries may claim it with no App Group and no
/// portal capability, because the team-wide `76S78SUWVM.*` wildcard is
/// already in both provisioning profiles.
///
/// The same string is duplicated in `ios/NotificationService/PushKeychain.swift`
/// and in both entitlements files; `hygiene.yml` fails when they disagree.
const pushKeychainAccessGroup = '76S78SUWVM.top.npcserver.slimm.push';

/// The platform keychain, through flutter_secure_storage. Use on iOS and
/// Android, where the OS itself guarantees a secure backend.
///
/// The iOS accessibility is device-bound: excluded from iCloud sync and from
/// local device backups, and it never migrates to a new device. The default
/// (kSecAttrAccessibleWhenUnlocked) rides into both, which hands a 30-day
/// refresh token and the push private key to whatever restores that backup.
class SecureKeyStore implements KeyStore {
  SecureKeyStore({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                // Device-bound; the default would ride into iCloud and local
                // backups. See the class doc comment.
                accessibility: KeychainAccessibility.unlocked_this_device,
              ),
            );

  /// The push private key's own store: [pushKeychainAccessGroup], and
  /// readable once the phone has been unlocked at all rather than only while
  /// it is unlocked right now.
  ///
  /// A push arriving on a locked phone is the entire point of a lock-screen
  /// preview, and that is exactly when
  /// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` refuses to hand the key
  /// over, so the extension would fall back to the generic string every time
  /// it mattered most.
  ///
  /// **The backup guarantee the default constructor's doc comment describes
  /// is untouched.** `ThisDeviceOnly` is the half of that attribute that
  /// excludes an item from iCloud and from local backups and stops it
  /// migrating to a new device, and it is kept here. The only thing that
  /// changes is readability while the screen is locked.
  ///
  /// Scoped to this one key on purpose: every other secret, the refresh token
  /// above all, stays on the stricter default above, where nothing can read
  /// it until the owner has unlocked the phone.
  SecureKeyStore.forPushKey({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                groupId: pushKeychainAccessGroup,
                accessibility: KeychainAccessibility.first_unlock_this_device,
              ),
            );

  final FlutterSecureStorage _storage;

  /// Exposed only so a test can assert on the configured options without a
  /// real keychain backend behind it; nothing outside a test should need
  /// this.
  @visibleForTesting
  FlutterSecureStorage get debugStorage => _storage;

  @override
  Future<KeyHandle> put(String name, String secret) async {
    await _storage.write(key: name, value: secret);
    return name;
  }

  @override
  Future<String?> read(KeyHandle handle) => _storage.read(key: handle);

  @override
  Future<void> delete(KeyHandle handle) => _storage.delete(key: handle);

  @override
  Future<void> clear() => _storage.deleteAll();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) {
    throw UnsupportedError(
      'signing needs a real key backend; wire one before shipping E2EE',
    );
  }
}

/// The Linux fallback: a single JSON file under the user's
/// application-support directory, in a directory restricted to this OS
/// account (0700), written through a 0600 temp file and renamed into place. See the library doc for why this, not
/// flutter_secure_storage, is used there, and for what this does and does
/// not defend against.
///
/// Every operation is queued behind the last: two calls racing a
/// read-modify-write of the same file on disk is exactly how a concurrent
/// write (a session write landing alongside an unrelated push-key write, say)
/// would silently lose one of them.
class FileKeyStore implements KeyStore {
  FileKeyStore({Directory? directory}) : _directory = directory;

  static const _fileName = 'slimm_secrets.json';

  /// Overridden by tests; production always resolves the real
  /// application-support directory.
  final Directory? _directory;

  Future<File>? _file;
  Future<void> _queue = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _queue.then((_) => action());
    _queue = result.then((_) {}, onError: (_) {});
    return result;
  }

  /// A rejected open must not be cached: an error is never the right thing
  /// to remember here, or one transient failure (a directory the OS could
  /// not create just then, a locked file) would disable storage for the
  /// rest of the process with no way back. The same reasoning is why
  /// http/ws/permission_cache.rs never caches a read error server-side.
  Future<File> _secretsFile() {
    return (_file ??= _open()).catchError((Object error, StackTrace stack) {
      _file = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<File> _open() async {
    final file = await _fileNoCreate();
    await file.parent.create(recursive: true);
    await _chmod('700', file.parent);
    if (!await file.exists()) {
      await file.create();
    }
    await _restrict(file);
    return file;
  }

  /// The file this store reads and writes, without creating it - unlike
  /// [_open], which every ordinary operation goes through. Used only by the
  /// migration helpers below, which must not conjure an empty file on a
  /// platform or install that never had one.
  Future<File> _fileNoCreate() async {
    final dir = _directory ?? await getApplicationSupportDirectory();
    return File(p.join(dir.path, _fileName));
  }

  /// Fails loudly: a store that could not make its file private must not go
  /// on to write secrets into it. Skipped on Windows, which has no POSIX mode
  /// bits to set (and is not a platform that uses this store for secrets).
  Future<void> _chmod(String mode, FileSystemEntity entity) async {
    if (Platform.isWindows) return;
    final result = await Process.run('chmod', [mode, entity.path]);
    if (result.exitCode != 0) {
      throw FileSystemException(
        'chmod $mode failed: ${result.stderr}',
        entity.path,
      );
    }
  }

  Future<void> _restrict(File file) => _chmod('600', file);

  /// A file that does not parse is treated as holding nothing: a torn write
  /// must cost a sign-in, not lock every later read out behind an exception.
  Future<Map<String, dynamic>> _readAll() async {
    final file = await _secretsFile();
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) return {};
    try {
      return jsonDecode(contents) as Map<String, dynamic>;
    } on FormatException {
      return {};
    } on TypeError {
      return {};
    }
  }

  /// Writes a private temp file in full, flushes it, then renames it over the
  /// real one, so a crash leaves the old contents or the new, never half of
  /// each. The temp file is restricted before anything is written to it.
  Future<void> _writeAll(Map<String, dynamic> data) async {
    final file = await _secretsFile();
    final temp = File('${file.path}.tmp');
    await temp.create();
    await _restrict(temp);
    final handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeString(jsonEncode(data));
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temp.rename(file.path);
  }

  @override
  Future<KeyHandle> put(String name, String secret) {
    return _serialized(() async {
      final data = await _readAll();
      data[name] = secret;
      await _writeAll(data);
      return name;
    });
  }

  @override
  Future<String?> read(KeyHandle handle) {
    return _serialized(() async {
      final data = await _readAll();
      return data[handle] as String?;
    });
  }

  @override
  Future<void> delete(KeyHandle handle) {
    return _serialized(() async {
      final data = await _readAll();
      data.remove(handle);
      await _writeAll(data);
    });
  }

  @override
  Future<void> clear() => _serialized(() => _writeAll({}));

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) {
    throw UnsupportedError(
      'signing needs a real key backend; wire one before shipping E2EE',
    );
  }

  /// Every entry currently on disk, for [migrateLegacyFileSecretsIfNeeded].
  /// Null, rather than an empty map, when the file does not exist at all -
  /// [_fileNoCreate] is used instead of [_secretsFile] specifically so asking
  /// never creates one, on a platform or install that never had it.
  Future<Map<String, String>?> readAllForMigration() async {
    final file = await _fileNoCreate();
    if (!await file.exists()) return null;
    final contents = await file.readAsString();
    if (contents.trim().isEmpty) return {};
    final data = jsonDecode(contents) as Map<String, dynamic>;
    return data.map((key, value) => MapEntry(key, value as String));
  }

  /// Deletes the file this store reads and writes. Only ever called once
  /// every entry [readAllForMigration] returned has been written somewhere
  /// else - see [migrateLegacyFileSecretsIfNeeded].
  Future<void> deleteLegacyFile() async {
    final file = await _fileNoCreate();
    if (await file.exists()) await file.delete();
  }
}

/// The platform facts [createPersistentKeyStore] switches on, gathered into
/// one value so a test can supply a fake one: `dart:io`'s `Platform.isX`
/// getters are the real OS, not something a test running on one CI runner
/// can flip to pretend to be another.
@visibleForTesting
class HostPlatformKind {
  const HostPlatformKind({
    required this.isWeb,
    required this.isIOS,
    required this.isAndroid,
    required this.isMacOS,
    required this.isWindows,
  });

  /// What this process is actually running on.
  factory HostPlatformKind.current() => HostPlatformKind(
        isWeb: kIsWeb,
        isIOS: isIOSHost,
        isAndroid: isAndroidHost,
        isMacOS: isMacOSHost,
        isWindows: isWindowsHost,
      );

  final bool isWeb;
  final bool isIOS;
  final bool isAndroid;
  final bool isMacOS;
  final bool isWindows;

  /// Whether this platform gets [SecureKeyStore] rather than [FileKeyStore].
  /// A browser has no filesystem to write an owner-only file to, so it is
  /// grouped with the three OSes whose keychain is always present; Linux is
  /// the one host left on the file (see the library doc for why).
  bool get usesSecureBackend =>
      isWeb || isIOS || isAndroid || isMacOS || isWindows;
}

/// Picks the right backend for this platform: the OS keychain on iOS,
/// Android, macOS and Windows, browser storage on the web (see the library
/// doc for how much weaker that is), and an owner-only-permissioned file on
/// Linux, the one platform whose flutter_secure_storage backend cannot
/// promise a running Secret Service (see the library doc).
KeyStore createPersistentKeyStore({HostPlatformKind? platform}) {
  final kind = platform ?? HostPlatformKind.current();
  return kind.usesSecureBackend ? SecureKeyStore() : FileKeyStore();
}

/// Moves secrets an earlier build left in [FileKeyStore] into
/// [SecureKeyStore], for the two platforms this version newly routes to the
/// keychain: macOS and Windows. A no-op everywhere else - Linux still uses
/// the file (see [createPersistentKeyStore]), and iOS, Android and the web
/// never wrote one, so there is nothing to move.
///
/// Every entry is written to the new store before the old file is deleted,
/// and the file is left untouched if reading it or writing any entry fails,
/// so a keychain that refuses a write this one time leaves the user's
/// session on the file rather than signed out with nothing to fall back to.
/// The next launch simply tries again.
///
/// Call before anything reads [createPersistentKeyStore]'s result for this
/// install's actual secrets - `restoreSession` in the app package is that
/// call site today.
Future<void> migrateLegacyFileSecretsIfNeeded() async {
  if (!isMacOSHost && !isWindowsHost) return;
  await migrateLegacyFileSecrets(
    legacy: FileKeyStore(),
    destination: SecureKeyStore(),
  );
}

/// The platform-independent move [migrateLegacyFileSecretsIfNeeded] performs,
/// split out so a test can supply an in-memory [destination] instead of a
/// real keychain and a [legacy] store pointed at a throwaway directory.
@visibleForTesting
Future<void> migrateLegacyFileSecrets({
  required FileKeyStore legacy,
  required KeyStore destination,
}) async {
  final Map<String, String>? entries;
  try {
    entries = await legacy.readAllForMigration();
  } catch (_) {
    return;
  }
  if (entries == null) return;

  try {
    for (final entry in entries.entries) {
      await destination.put(entry.key, entry.value);
    }
  } catch (_) {
    return;
  }
  await legacy.deleteLegacyFile();
}

/// Whether the push private key lives somewhere other than where every other
/// secret does, which is true on iOS and nowhere else.
///
/// The keychain group and the accessibility [SecureKeyStore.forPushKey]
/// carries are iOS attributes that mean nothing to the Android keystore, the
/// macOS/Windows keychain, the Linux file, or a browser, and no other
/// platform has a second process that needs to read this key.
///
/// Callers must ask this rather than comparing stores: off iOS the push key
/// has to use the *same instance* [createPersistentKeyStore] returned, not an
/// equivalent one, because [FileKeyStore] serialises writes per instance and
/// two of them over one file would reintroduce the lost-update race that
/// queue exists to prevent.
bool get pushKeyHasItsOwnStore => isIOSHost;

/// The push key's own store. Only meaningful where [pushKeyHasItsOwnStore];
/// everywhere else the answer is whatever [createPersistentKeyStore] already
/// returned.
///
/// An item written with no access group and
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` does not match a query
/// naming a group and a different accessibility - both attributes are part of
/// the search - so a key an earlier build wrote is invisible here, and
/// `DevicePushKeys` does the one-time move rather than silently generating a
/// second keypair and orphaning every envelope sealed to the first.
KeyStore createPushKeyStore() => SecureKeyStore.forPushKey();
