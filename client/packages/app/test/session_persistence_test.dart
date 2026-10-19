// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the session lifecycle across a restart: restoring what was
/// persisted, restoring the server it belongs to, discovering a restored
/// session is no longer valid, clearing a leftover keychain session on the
/// first launch after an install, and clearing everything a sign-out owns.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
// Channel and Message exist in both packages; the wire types are the ones
// this file builds, so only the store types come across from data.
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

const _serverUrl = 'http://10.0.0.100:8095';

/// A key store that throws on every call, standing in for a broken storage
/// layer (a locked file, a keychain the OS refuses to open, and so on).
class _ThrowingKeyStore implements KeyStore {
  @override
  Future<KeyHandle> put(String name, String secret) async =>
      throw StateError('storage unavailable');

  @override
  Future<String?> read(KeyHandle handle) async =>
      throw StateError('storage unavailable');

  @override
  Future<void> delete(KeyHandle handle) async =>
      throw StateError('storage unavailable');

  @override
  Future<void> clear() async => throw StateError('storage unavailable');

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) async =>
      throw StateError('storage unavailable');
}

/// Delegates to a real [InMemoryKeyStore], but its very first [put] blocks
/// until a test explicitly [release]s it. Lets a test force two writes to
/// overlap deterministically, without depending on wall-clock timing: an
/// implementation that fires writes in parallel rather than chaining them
/// lets the second (fast) write land before the first (held back) one, which
/// then finishes last and clobbers it.
class _GatedKeyStore implements KeyStore {
  _GatedKeyStore(this._inner);

  final InMemoryKeyStore _inner;
  final _gate = Completer<void>();
  int putCalls = 0;

  void release() => _gate.complete();

  @override
  Future<KeyHandle> put(String name, String secret) async {
    putCalls++;
    if (putCalls == 1) await _gate.future;
    return _inner.put(name, secret);
  }

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

/// Delegates to a real [InMemoryKeyStore] but lets a test make the next
/// [put] fail once, to exercise a write that is lost partway through.
class _FlakyKeyStore implements KeyStore {
  _FlakyKeyStore(this._inner);

  final InMemoryKeyStore _inner;
  bool failNextPut = false;

  @override
  Future<KeyHandle> put(String name, String secret) {
    if (failNextPut) {
      failNextPut = false;
      throw StateError('disk full');
    }
    return _inner.put(name, secret);
  }

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Every restoreSession() call reads the first-launch flag from
  /// SharedPreferences; marking the app as "already launched" is what makes
  /// these tests the ordinary "restart", not a fresh install, unless a test
  /// is specifically about that first-launch behaviour.
  setUp(
    () => SharedPreferences.setMockInitialValues({hasLaunchedBeforeKey: true}),
  );

  group('restoreSession', () {
    test('a persisted session is restored on a fresh launch', () async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keyStore.put(serverUrlHandle, _serverUrl);

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      final session = container.read(sessionProvider);
      expect(session.isSignedIn, isTrue);
      expect(session.tokens!.accessToken, 'access-1');
      expect(session.tokens!.userId, 'user-1');
    });

    test('a restored session restores the server it was signed into, not '
        'serverUrlProvider\'s localhost default', () async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keyStore.put(serverUrlHandle, _serverUrl);

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      expect(container.read(serverUrlProvider), Uri.parse(_serverUrl));
    });

    test('a session with no persisted server address is dropped rather than '
        'restored against the useless default', () async {
      final keyStore = InMemoryKeyStore();

      /// A session persisted with no matching server address: the exact shape
      /// of the bug this guards, reproduced directly rather than only through
      /// the write path.
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      expect(container.read(sessionProvider).isSignedIn, isFalse);
      expect(
        container.read(serverUrlProvider),
        Uri.parse('http://localhost:8080'),
        reason: 'never silently left pointed at the default either',
      );
    });

    test('a remembered server survives a sign-out and is restored on the next '
        'launch, so recovery never means retyping the address', () async {
      // Exactly what sign-out leaves on disk: the session token is deleted,
      // the address of the server it was signed into is not.
      final keyStore = InMemoryKeyStore();
      await keyStore.put(serverUrlHandle, _serverUrl);

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      expect(container.read(sessionProvider).isSignedIn, isFalse);
      expect(
        container.read(chosenServerProvider),
        Uri.parse(_serverUrl),
        reason: 'the server is remembered independently of any session',
      );
      expect(container.read(serverUrlProvider), Uri.parse(_serverUrl));
    });

    test('nothing persisted leaves a fresh launch signed out', () async {
      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      expect(container.read(sessionProvider).isSignedIn, isFalse);
    });

    test(
      'a corrupt persisted session is dropped rather than crashing launch',
      () async {
        final keyStore = InMemoryKeyStore();
        await keyStore.put(sessionTokenHandle, 'not valid json');

        final container = ProviderContainer(
          overrides: [keyStoreProvider.overrideWithValue(keyStore)],
        );
        addTearDown(container.dispose);

        await restoreSession(container);

        expect(container.read(sessionProvider).isSignedIn, isFalse);
        expect(await keyStore.read(sessionTokenHandle), isNull);
      },
    );

    test('a key store that throws on read degrades to signed out, not a '
        'crashed launch', () async {
      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(_ThrowingKeyStore())],
      );
      addTearDown(container.dispose);

      // main() awaits this before runApp; if this completed with an error
      // instead of gracefully, the app would never launch at all.
      await expectLater(restoreSession(container), completes);
      expect(container.read(sessionProvider).isSignedIn, isFalse);
    });

    test('the first launch after an install clears a leftover keychain '
        'session rather than restoring it', () async {
      SharedPreferences.setMockInitialValues({});
      final keyStore = InMemoryKeyStore();
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keyStore.put(serverUrlHandle, _serverUrl);

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      await restoreSession(container);

      expect(container.read(sessionProvider).isSignedIn, isFalse);
      expect(
        await keyStore.read(sessionTokenHandle),
        isNull,
        reason:
            'a keychain item that survived a supposed uninstall must '
            'not come back as this install\'s session',
      );
    });

    test('a later, ordinary launch does not re-clear a session that was '
        'genuinely restored', () async {
      SharedPreferences.setMockInitialValues({});
      final keyStore = InMemoryKeyStore();
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keyStore.put(serverUrlHandle, _serverUrl);

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      // First launch: clears the pre-existing keychain leftovers.
      await restoreSession(container);
      expect(container.read(sessionProvider).isSignedIn, isFalse);

      // A real sign-in on this (now first-launched) install.
      container.read(sessionProvider).set(_tokens);
      await pumpEventQueue();

      // A later relaunch of the same install must restore it normally.
      final relaunch = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(relaunch.dispose);
      await restoreSession(relaunch);

      expect(relaunch.read(sessionProvider).isSignedIn, isTrue);
    });

    test('a restored session whose refresh token is rejected ends up signed '
        'out, and only once, not in a loop', () async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      await keyStore.put(serverUrlHandle, _serverUrl);

      var refreshAttempts = 0;
      final session = SessionStore();
      final api = testApi((request) async {
        expect(
          request.url.path,
          '/auth/refresh',
          reason: 'the only authenticated call this test makes',
        );
        refreshAttempts++;
        return http.Response('{"error":"revoked"}', 401);
      }, session: session);
      addTearDown(api.close);

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(keyStore),
          sessionProvider.overrideWithValue(session),
          apiProvider.overrideWithValue(api),
        ],
      );
      addTearDown(container.dispose);

      await restoreSession(container);
      expect(
        session.isSignedIn,
        isTrue,
        reason: 'restored optimistically, before any network round trip',
      );

      await expectLater(api.refresh, throwsA(isA<UnauthorizedException>()));

      expect(session.isSignedIn, isFalse);
      expect(refreshAttempts, 1);
    });
  });

  group('session persistence writes', () {
    test('the server address is persisted alongside a fresh session', () async {
      final keyStore = InMemoryKeyStore();
      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_serverUrl));
      container.read(sessionProvider).set(_tokens);
      await pumpEventQueue();

      expect(await keyStore.read(serverUrlHandle), _serverUrl);
    });

    test('choosing a server persists it before any session exists', () async {
      // Picking a server and closing the app before signing in still says
      // where the user was going; forgetting it means onboarding again.
      final keyStore = InMemoryKeyStore();
      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      container
          .read(chosenServerProvider.notifier)
          .choose(Uri.parse(_serverUrl));
      await pumpEventQueue();

      expect(await keyStore.read(serverUrlHandle), _serverUrl);
    });

    test('a burst of rapid session changes is written to disk in the order '
        'they happened, not whichever write finishes first', () async {
      final inner = InMemoryKeyStore();
      final keyStore = _GatedKeyStore(inner);
      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      final session = container.read(sessionProvider);
      const first = TokenPair(
        userId: 'user-1',
        accessToken: 'access-first',
        refreshToken: 'refresh-first',
        accessExpiresAt: 0,
      );
      const second = TokenPair(
        userId: 'user-1',
        accessToken: 'access-second',
        refreshToken: 'refresh-second',
        accessExpiresAt: 0,
      );

      /// Two changes back to back, neither awaited individually: exactly the
      /// shape of a restore immediately followed by a refresh. The first
      /// write is held open by the gate; an unchained implementation lets the
      /// second race ahead of it regardless.
      session.set(first);
      session.set(second);
      await pumpEventQueue();
      keyStore.release();
      await pumpEventQueue();

      final stored = await keyStore.read(sessionTokenHandle);
      final persisted = TokenPair.fromJson(
        jsonDecode(stored!) as Map<String, dynamic>,
      );
      expect(
        persisted.accessToken,
        'access-second',
        reason:
            'the later change must win on disk, not whichever write '
            'happened to finish first',
      );
    });

    test('a write that fails drops the stored session rather than leaving a '
        'stale, already-spent token behind', () async {
      final inner = InMemoryKeyStore();
      await inner.put(sessionTokenHandle, jsonEncode(_tokens.toJson()));
      final keyStore = _FlakyKeyStore(inner)..failNextPut = true;

      final container = ProviderContainer(
        overrides: [keyStoreProvider.overrideWithValue(keyStore)],
      );
      addTearDown(container.dispose);

      // A rotation whose persistence write fails.
      container
          .read(sessionProvider)
          .set(
            const TokenPair(
              userId: 'user-1',
              accessToken: 'access-rotated',
              refreshToken: 'refresh-rotated',
              accessExpiresAt: 0,
            ),
          );
      await pumpEventQueue();

      expect(
        await inner.read(sessionTokenHandle),
        isNull,
        reason:
            'the old, now-spent refresh token must not survive on '
            'disk for the next launch to replay',
      );
    });
  });

  group('sign-out', () {
    test('clears both the persisted session and the device push key', () async {
      final keyStore = InMemoryKeyStore();

      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(keyStore),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: ref.watch(serverUrlProvider),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((_) async => http.Response('', 204)),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      // Sign in the way login() does: setting the session is what the
      // sessionProvider's own listener persists.
      container.read(sessionProvider).set(_tokens);
      await pumpEventQueue();
      expect(await keyStore.read(sessionTokenHandle), isNotNull);

      // Seed a device push key the way a real registration would.
      await DevicePushKeys(keyStore).publicKeyBase64();
      expect(await keyStore.read(devicePushKeyHandle), isNotNull);

      // The settings screen's sign-out sequence: drop the push registration
      // and key first, then end the session.
      await container.read(pushControllerProvider.notifier).unregister();
      await container.read(apiProvider).logout();
      await pumpEventQueue();

      expect(await keyStore.read(devicePushKeyHandle), isNull);
      expect(await keyStore.read(sessionTokenHandle), isNull);
      expect(container.read(sessionProvider).isSignedIn, isFalse);
    });

    test(
      'drops the cached channels and messages the session was reading',
      () async {
        /// The local database is one file for the whole app, not one per account
        /// or per server. Without this, the next person to sign in on the device
        /// opens straight onto the previous account's channel list and message
        /// text, before any sync could correct it.
        final db = SlimmDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final store = MessageStore(db);

        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
            storeProvider.overrideWith((ref) async => store),
            apiProvider.overrideWith((ref) {
              final api = SlimmApi(
                baseUrl: ref.watch(serverUrlProvider),
                session: ref.watch(sessionProvider),
                httpClient: MockClient((_) async => http.Response('', 204)),
              );
              ref.onDispose(api.close);
              return api;
            }),
          ],
        );
        addTearDown(container.dispose);

        await store.upsertChannels([
          const Channel(
            id: 'chan-1',
            name: 'general',
            kind: 'text',
            createdAt: 1,
          ),
        ]);
        await store.applyMessage(
          const Message(
            id: 'm1',
            channelId: 'chan-1',
            authorId: 'user-1',
            authorDisplayName: 'User One',
            seq: 1,
            content: 'private to the account signing out',
            createdAt: 1000,
            editedAt: null,
          ),
        );

        // Bring the sync controller up so it is listening to the session, the
        // way the app shell does.
        container.read(syncControllerProvider.notifier);
        container.read(sessionProvider).set(_tokens);
        await pumpEventQueue();
        expect(await store.watchChannel('chan-1').first, hasLength(1));

        await container.read(apiProvider).logout();
        await pumpEventQueue();

        expect(container.read(sessionProvider).isSignedIn, isFalse);
        expect(
          await store.watchChannel('chan-1').first,
          isEmpty,
          reason: 'the previous account\'s messages must not survive',
        );
        expect(
          await store.watchChannels().first,
          isEmpty,
          reason: 'nor the channel list, which names the server they were on',
        );
      },
    );
  });
}
