// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linux keeps secrets in the Secret Service when one answers and in the
/// owner-only file when none does.
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late FileKeyStore file;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('slimm_linux_store_');
    file = FileKeyStore(directory: dir);
  });
  tearDown(() => dir.deleteSync(recursive: true));

  File secretsFile() => File('${dir.path}/slimm_secrets.json');

  test('with a Secret Service, secrets go there and not to the file', () async {
    final keyring = InMemoryKeyStore();
    final store = LinuxKeyStore(file: file, secretService: keyring);

    await store.put('session', 'refresh-token');

    expect(await keyring.read('session'), 'refresh-token');
    expect(secretsFile().existsSync(), isFalse);
  });

  test('entries already in the file move over and the file is removed',
      () async {
    await file.put('session', 'refresh-token');
    await file.put('slimm.database.key', 'db-key');
    final keyring = InMemoryKeyStore();
    final store = LinuxKeyStore(file: file, secretService: keyring);

    expect(await store.read('session'), 'refresh-token');

    expect(await keyring.read('slimm.database.key'), 'db-key');
    expect(secretsFile().existsSync(), isFalse);
  });

  test('without a Secret Service, the file keeps working', () async {
    final store = LinuxKeyStore(file: file, secretService: _Unavailable());

    await store.put('session', 'refresh-token');

    expect(await store.read('session'), 'refresh-token');
    expect(await file.read('session'), 'refresh-token');
  });

  test('a Secret Service that never answers falls back to the file', () async {
    final store = LinuxKeyStore(
      file: file,
      secretService: _Hanging(),
      probeTimeout: const Duration(milliseconds: 50),
    );

    await store.put('session', 'refresh-token');

    expect(await file.read('session'), 'refresh-token');
  });

  test('a failed move leaves the file as the store for this run', () async {
    await file.put('session', 'refresh-token');
    final store = LinuxKeyStore(
      file: file,
      secretService: _ProbeOnly(),
    );

    expect(await store.read('session'), 'refresh-token');
    expect(secretsFile().existsSync(), isTrue);
  });

  test(
      'once migrated, a keyring that stops answering is unavailable, not empty',
      () async {
    await file.put('session', 'refresh-token');
    final keyring = _Switchable();
    await LinuxKeyStore(file: file, secretService: keyring).read('session');
    keyring.answering = false;
    final next = LinuxKeyStore(
      file: file,
      secretService: keyring,
      probeTimeout: const Duration(milliseconds: 50),
    );

    await expectLater(
        next.read('session'), throwsA(isA<KeyringUnavailableException>()));
    expect(secretsFile().existsSync(), isFalse);

    keyring.answering = true;
    expect(await next.read('session'), 'refresh-token');
  });

  test('a later move never overwrites what the keyring already holds',
      () async {
    final keyring = InMemoryKeyStore();
    await keyring.put('slimm.accounts', 'kept');
    await file.put('slimm.accounts', 'stale');

    await migrateLegacyFileSecrets(legacy: file, destination: keyring);

    expect(await keyring.read('slimm.accounts'), 'kept');
  });

  test('the probe leaves nothing behind in the Secret Service', () async {
    final keyring = _Recording();
    final store = LinuxKeyStore(file: file, secretService: keyring);

    await store.read('anything');

    expect(keyring.written, hasLength(1));
    expect(await keyring.read(keyring.written.single), isNull);
  });

  test('delete and clear reach the store in use', () async {
    final keyring = InMemoryKeyStore();
    final store = LinuxKeyStore(file: file, secretService: keyring);
    await store.put('a', '1');
    await store.put('b', '2');

    await store.delete('a');
    expect(await keyring.read('a'), isNull);
    await store.clear();
    expect(await keyring.read('b'), isNull);
  });

  testWidgets('an answered probe leaves no timer pending', (tester) async {
    final store = LinuxKeyStore(file: file, secretService: InMemoryKeyStore());

    await tester.runAsync(() => store.read('anything'));
  });

  test('createPersistentKeyStore picks this store on Linux', () {
    const linux = HostPlatformKind(
      isWeb: false,
      isIOS: false,
      isAndroid: false,
      isMacOS: false,
      isWindows: false,
    );
    expect(createPersistentKeyStore(platform: linux), isA<LinuxKeyStore>());
  });
}

class _Unavailable extends InMemoryKeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) =>
      throw StateError('org.freedesktop.secrets was not provided');
}

class _Recording extends InMemoryKeyStore {
  final written = <String>[];

  @override
  Future<KeyHandle> put(String name, String secret) {
    written.add(name);
    return super.put(name, secret);
  }
}

class _Hanging extends InMemoryKeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) =>
      Completer<KeyHandle>().future;
}

/// Answers the probe but refuses every real entry, so a move cannot finish.
class _ProbeOnly extends InMemoryKeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) async {
    if (!name.startsWith(LinuxKeyStore.probeHandle)) {
      throw StateError('refused');
    }
    return super.put(name, secret);
  }
}

class _Switchable extends InMemoryKeyStore {
  bool answering = true;

  @override
  Future<KeyHandle> put(String name, String secret) =>
      answering ? super.put(name, secret) : Completer<KeyHandle>().future;
}
