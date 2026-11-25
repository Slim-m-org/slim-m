// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A missing first-launch flag only means a fresh install where the keychain
/// outlives the app, and never while the device or the store cannot be read.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/accounts/providers/account_restore.dart';
import 'package:slimm_app/src/providers/fresh_install.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

class _FlakyKeyStore extends InMemoryKeyStore {
  bool failReads = false;
  int clears = 0;

  @override
  Future<String?> read(KeyHandle handle) async {
    if (failReads) throw StateError('errSecInteractionNotAllowed');
    return super.read(handle);
  }

  @override
  Future<void> clear() {
    clears++;
    return super.clear();
  }
}

const _desktop = FirstLaunchEnvironment(
  keychainOutlivesInstall: false,
  protectedDataAvailable: _yes,
);
const _ios = FirstLaunchEnvironment(
  keychainOutlivesInstall: true,
  protectedDataAvailable: _yes,
);
const _iosLocked = FirstLaunchEnvironment(
  keychainOutlivesInstall: true,
  protectedDataAvailable: _no,
);

Future<bool> _yes() async => true;
Future<bool> _no() async => false;

Future<_FlakyKeyStore> _signedIn() async {
  final store = _FlakyKeyStore();
  await store.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
  await store.put(serverUrlHandle, 'http://10.0.0.100:8095');
  return store;
}

ProviderContainer _container(KeyStore store, FirstLaunchEnvironment env) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(store),
      pushKeyStoreProvider.overrideWithValue(store),
      firstLaunchEnvironmentProvider.overrideWithValue(env),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('an empty prefs read beside stored secrets keeps the secrets', () async {
    final store = await _signedIn();

    final fresh = await wipeKeychainOnFreshInstall(_container(store, _desktop));

    expect(fresh, isFalse);
    expect(await store.read(sessionTokenHandle), isNotNull);
    expect(
      (await SharedPreferences.getInstance()).getBool(hasLaunchedBeforeKey),
      isTrue,
    );
  });

  test('restoreSession keeps the session when the flag is lost', () async {
    final store = await _signedIn();
    final container = _container(store, _desktop);

    await restoreSession(container);

    expect(container.read(sessionProvider).isSignedIn, isTrue);
    expect(container.read(isFreshInstallProvider), isFalse);
  });

  test('a first launch with an empty store is a fresh install', () async {
    final store = _FlakyKeyStore();
    final container = _container(store, _desktop);

    expect(await wipeKeychainOnFreshInstall(container), isTrue);
    expect(container.read(isFreshInstallProvider), isTrue);
  });

  test('a reinstall on iOS drops the keychain it left behind', () async {
    final store = await _signedIn();

    expect(await wipeKeychainOnFreshInstall(_container(store, _ios)), isTrue);
    expect(await store.read(sessionTokenHandle), isNull);
  });

  test('a launch before first unlock keeps the signed-in account', () async {
    final store = await _signedIn();

    expect(
      await wipeKeychainOnFreshInstall(_container(store, _iosLocked)),
      isFalse,
    );

    expect(store.clears, 0);
    expect(await store.read(sessionTokenHandle), isNotNull);
    expect(
      (await SharedPreferences.getInstance()).getBool(hasLaunchedBeforeKey),
      isNull,
    );
  });

  test('a store that cannot be read is never cleared', () async {
    final store = await _signedIn()
      ..failReads = true;

    expect(await wipeKeychainOnFreshInstall(_container(store, _ios)), isFalse);

    expect(store.clears, 0);
  });
}
