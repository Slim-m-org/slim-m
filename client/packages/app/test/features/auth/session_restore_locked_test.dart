// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Storage that cannot be read yet at launch (a phone woken by a push before
/// it is unlocked, a desktop keyring not yet open) must not sign anyone out.
/// It used to delete the stored session, which left the server session alive
/// and push notifications arriving on a device that showed the sign-in screen.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);
const _serverUrl = 'http://10.0.0.100:8095';

/// A real store whose reads throw while [locked], like a keychain before unlock.
class _LockableKeyStore implements KeyStore {
  final inner = InMemoryKeyStore();
  bool locked = true;

  @override
  Future<KeyHandle> put(String name, String secret) => inner.put(name, secret);

  @override
  Future<String?> read(KeyHandle handle) async {
    if (locked) throw StateError('errSecInteractionNotAllowed');
    return inner.read(handle);
  }

  @override
  Future<void> delete(KeyHandle handle) => inner.delete(handle);

  @override
  Future<void> clear() => inner.clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      inner.sign(handle, payload);
}

Future<_LockableKeyStore> _storedSession() async {
  final store = _LockableKeyStore();
  await store.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
  await store.put(serverUrlHandle, _serverUrl);
  return store;
}

ProviderContainer _container(KeyStore store) {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(store)],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a locked store at launch keeps the stored session', () async {
    SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true});
    final store = await _storedSession();

    await restoreSession(_container(store));

    expect(await store.inner.read(sessionTokenHandle), isNotNull);
  });

  test(
    'a locked store never reads as a fresh install and wipes the keychain',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = await _storedSession();

      await restoreSession(_container(store));

      expect(await store.inner.read(sessionTokenHandle), isNotNull);
    },
  );

  test('once the store unlocks, a retry signs the session back in', () async {
    SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true});
    final store = await _storedSession();
    final container = _container(store);

    await restoreSession(container, firstRetry: _retry);
    expect(container.read(sessionProvider).isSignedIn, isFalse);
    expect(container.read(sessionRestoreNoteProvider), contains('unreadable'));

    store.locked = false;
    await _waitFor(() => container.read(sessionProvider).isSignedIn);

    expect(container.read(sessionProvider).tokens!.accessToken, 'access-1');
    expect(container.read(sessionRestoreNoteProvider), contains('restored'));
  });

  test(
    'a sign-in while waiting is never replaced by the stored session',
    () async {
      SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true});
      final store = await _storedSession();
      final container = _container(store);
      await restoreSession(container, firstRetry: _retry);

      const fresh = TokenPair(
        userId: 'user-1',
        accessToken: 'access-2',
        refreshToken: 'refresh-2',
        accessExpiresAt: 0,
      );
      container.read(sessionProvider).set(fresh);
      store.locked = false;
      await Future<void>.delayed(_retry * 8);

      expect(container.read(sessionProvider).tokens!.accessToken, 'access-2');
    },
  );

  test('a stored session that reads but is corrupt is still dropped', () async {
    SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true});
    final store = _LockableKeyStore()..locked = false;
    await store.put(sessionTokenHandle, 'not json');
    await store.put(serverUrlHandle, _serverUrl);
    final container = _container(store);

    await restoreSession(container);

    expect(await store.inner.read(sessionTokenHandle), isNull);
    expect(container.read(sessionRestoreNoteProvider), contains('dropped'));
  });
}

const _retry = Duration(milliseconds: 10);

Future<void> _waitFor(bool Function() done) async {
  for (var i = 0; i < 100 && !done(); i++) {
    await Future<void>.delayed(_retry);
  }
}
