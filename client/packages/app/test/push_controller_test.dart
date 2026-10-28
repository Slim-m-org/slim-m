// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for push registration: gated on a session, tracked as an honest
/// status rather than swallowed silence, and retried on resume and on a
/// session already signed in when the controller is created (a restored
/// session never passes through the sign-in screen that would otherwise
/// have kicked it off).
library;

import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/diagnostics/debug_log.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';
import 'support/push_controller_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  setUpAll(registerAndroidLocalNotificationsPluginForTest);
  // Every registration now reads the content-preview setting, which needs it.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('PushController construction', () {
    test('a token source whose rotation stream throws synchronously cannot '
        'break constructing the controller', () async {
      /// Signed in at construction, so the constructor also fires its own
      /// already-signed-in registration attempt over the iOS channel below -
      /// the point under test is that reading fcmTokenChannelProvider's
      /// onTokenRefresh getter, which throws here the way FirebaseMessaging
      /// does with no default Firebase app, never gets the chance to take
      /// that down with it.
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
        fcmChannel: FcmTokenChannel(
          source: ThrowingRefreshFcmTokenSource(),
          isAndroid: true,
        ),
      );
      addTearDown(container.dispose);

      expect(
        () => container.read(pushControllerProvider.notifier),
        returnsNormally,
      );

      /// Construction surviving is the headline assertion, but the rest of
      /// the controller must still work normally afterwards too: nothing
      /// about the guard should leave it half-built.
      await pumpEventQueue();
      expect(container.read(pushControllerProvider), PushStatus.registered);
    });
  });

  group('PushController.register', () {
    test('without a session, nothing is attempted', () async {
      /// The default sessionProvider starts signed out; nothing is overridden,
      /// so a real network call or a real MethodChannel round-trip would both
      /// be surfaced failures, proving the session check runs before either.
      final container = pushTestContainer(
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.notSignedIn);
    });

    test('a server failure never propagates out of register()', () async {
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('busy', 503)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      // No expectLater/throwsA here on purpose: the assertion is that this
      // completes at all.
      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.serverError);
    });

    test('a server failure reaches the debug log under the push tag', () async {
      final log = DebugLog();
      AppLog.install(log);
      addTearDown(() => AppLog.install(null));
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final container = pushTestContainer(
        session: SessionStore(tokens: pushTestTokens),
        httpClient: MockClient((_) async => http.Response('busy', 503)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();

      final entry = log.state.firstWhere((e) => e.source == LogTag.push);
      expect(entry.message, contains('register this device'));
      expect(entry.context['kind'], 'offline');
    });
  });

  group('push status transitions', () {
    test('unsupported platform is reported, not a silent no-token', () async {
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('unused', 500)),
        channel: ApnsTokenChannel(isIOS: false),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(
        container.read(pushControllerProvider),
        PushStatus.unsupportedPlatform,
      );
    });

    test(
      'no answer at all is reported as still waiting, not a silent no-op',
      () async {
        /// No mock handler is installed, so the channel throws
        /// MissingPluginException exactly as a genuine timeout would eventually
        /// resolve, without this test having to wait one out.
        mockPushChannel(null);
        final session = SessionStore(tokens: pushTestTokens);
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((_) async => http.Response('unused', 500)),
          channel: ApnsTokenChannel(isIOS: true),
        );
        addTearDown(container.dispose);

        await container.read(pushControllerProvider.notifier).register();
        expect(container.read(pushControllerProvider), PushStatus.noTokenYet);
      },
    );

    test('a native registration failure is reported, not swallowed', () async {
      mockPushChannel(
        (call) async => switch (call.method) {
          'getRegistrationError' => 'denied',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('unused', 500)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(
        container.read(pushControllerProvider),
        PushStatus.registrationFailed,
      );
    });

    test('a token accepted by the server ends up registered', () async {
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.registered);
    });

    test('a session already signed in when the controller is created '
        'registers without an explicit call', () async {
      /// Stands in for a session restored on launch: nothing on the sign-in
      /// screen ever ran, so the only thing that can start registration is the
      /// controller noticing it was constructed already signed in.
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      // Touching the provider is what constructs the controller; nothing
      // else here calls register() at all.
      container.read(pushControllerProvider.notifier);
      await pumpEventQueue();

      expect(container.read(pushControllerProvider), PushStatus.registered);
    });

    test('resuming retries when not yet registered', () async {
      mockPushChannel(null);
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      // No handler yet, so the first attempt lands on "still waiting".
      final controller = container.read(pushControllerProvider.notifier);
      await controller.register();
      expect(container.read(pushControllerProvider), PushStatus.noTokenYet);

      // The token arrives before the next attempt, the way a slow permission
      // prompt resolves while the app sits backgrounded.
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(container.read(pushControllerProvider), PushStatus.registered);
    });

    test('resuming does not retry once already registered', () async {
      var registerPushCalls = 0;
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      /// Starts signed out, so touching the notifier below does not also fire
      /// the constructor's own already-signed-in registration attempt
      /// alongside this test's: signing in afterwards is the single, clean
      /// trigger this test counts against.
      final session = SessionStore();
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            registerPushCalls++;
          }
          return http.Response('', 204);
        }),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      final controller = container.read(pushControllerProvider.notifier);
      session.set(pushTestTokens);
      await pumpEventQueue();
      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(registerPushCalls, 1);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      // Already registered, so resuming must not re-hit the server.
      expect(registerPushCalls, 1);
    });

    test(
      'repeated transitions to the same label report to the server once',
      () async {
        var lifecycleCalls = 0;
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        addTearDown(() => mockPushChannel(null));
        final session = SessionStore();
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((request) async {
            if (request.url.path == '/push/lifecycle') lifecycleCalls++;
            return http.Response('', 204);
          }),
          channel: ApnsTokenChannel(isIOS: true),
        );
        addTearDown(container.dispose);

        final controller = container.read(pushControllerProvider.notifier);
        session.set(pushTestTokens);
        await pumpEventQueue();
        controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await pumpEventQueue();
        final settled = lifecycleCalls;

        for (var i = 0; i < 5; i++) {
          controller.didChangeAppLifecycleState(AppLifecycleState.inactive);
          controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
          await pumpEventQueue();
        }
        expect(lifecycleCalls, settled, reason: 'alt-tabbing is not a change');

        controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
        await pumpEventQueue();
        expect(lifecycleCalls, settled + 1);
      },
    );

    test('signing out resets status to notSignedIn', () async {
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.registered);

      session.clear();
      await pumpEventQueue();

      expect(container.read(pushControllerProvider), PushStatus.notSignedIn);
    });

    test('a routine token rotation does not re-run registration: only the '
        'signed-out/signed-in edge does', () async {
      var getTokenCalls = 0;
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => () {
            getTokenCalls++;
            return 'abcd1234';
          }(),
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(getTokenCalls, 1);

      /// The server rotates access tokens well inside a live session, not
      /// just at sign-in and sign-out; a non-null token pair replacing another
      /// non-null one is that same rotation, not a new sign-in.
      session.set(
        const TokenPair(
          userId: 'user-1',
          accessToken: 'access-2',
          refreshToken: 'refresh-2',
          accessExpiresAt: 0,
        ),
      );
      await pumpEventQueue();

      expect(
        getTokenCalls,
        1,
        reason:
            'a token rotation is not a sign-in edge; it must not '
            'restart APNs registration',
      );
    });

    test('two concurrent register() calls share one attempt, not two racing '
        'to register a keypair', () async {
      var registerPushCalls = 0;
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => mockPushChannel(null));

      /// Already signed in at construction, so touching the notifier below
      /// also fires the constructor's own already-signed-in attempt: a third,
      /// uncoordinated caller alongside the two explicit ones.
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            registerPushCalls++;
          }
          return http.Response('', 204);
        }),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);

      final controller = container.read(pushControllerProvider.notifier);
      final first = controller.register();
      final second = controller.register();
      await Future.wait([first, second]);
      await pumpEventQueue();

      expect(
        registerPushCalls,
        1,
        reason:
            'two concurrent first registrations can each mint their '
            'own device keypair and race to tell the server which is '
            'current, leaving the loser\'s private half discarded locally '
            'while the server still holds its public half',
      );
    });
  });

  group('PushController.unregister', () {
    test(
      'a key-store failure while dropping the push key still completes '
      'and reaches notSignedIn, rather than aborting sign-out mid-way',
      () async {
        final session = SessionStore(tokens: pushTestTokens);
        final container = ProviderContainer(
          overrides: [
            keyStoreProvider.overrideWithValue(_DeleteFailingKeyStore()),
            sessionProvider.overrideWithValue(session),
            mockApiOverride((_) async => http.Response('', 204)),
          ],
        );
        addTearDown(container.dispose);

        final controller = container.read(pushControllerProvider.notifier);
        // main.dart's sign-out sequence has no try/catch around this call:
        // unregister() itself must never throw.
        await expectLater(controller.unregister(), completes);
        expect(container.read(pushControllerProvider), PushStatus.notSignedIn);
      },
    );
  });

  group('foreground lifecycle heartbeat', () {
    test('a foregrounded app keeps re-reporting on its own, so staying on '
        'one screen for minutes never crosses the server\'s one-minute '
        'staleness window and starts a notification for the exact screen '
        'already in front of the user', () {
      fakeAsync((async) {
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );

        final session = SessionStore(tokens: pushTestTokens);
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' &&
                request.url.path == '/push/lifecycle') {
              lifecycleReports.add(
                (jsonDecode(request.body) as Map<String, dynamic>)['state']
                    as String,
              );
            }
            return http.Response('', 204);
          }),
          channel: ApnsTokenChannel(isIOS: true),
        );

        /// Already signed in, so construction registers and reports the
        /// current (foreground) lifecycle once on its own, exactly as it
        /// does today on a fresh registration.
        container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();
        expect(lifecycleReports, ['foreground']);

        /// Stay right where it is for well past a minute, with no lifecycle
        /// transition of any kind - the exact shape of someone reading a
        /// channel for a few minutes.
        async.elapse(const Duration(minutes: 3));

        expect(
          lifecycleReports.length,
          greaterThan(1),
          reason:
              'without a heartbeat, the server\'s foreground report '
              'goes stale after a minute and starts sending push for a '
              'screen the user never left',
        );
        expect(
          lifecycleReports.toSet(),
          {'foreground'},
          reason:
              'every one of these is a re-report of the same '
              'unchanged state, not a spurious transition',
        );

        container.dispose();
        async.flushMicrotasks();
      });
    });

    test('a background launch that was never resumed reports background and '
        'starts no heartbeat', () {
      fakeAsync((async) {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.resetInternalState();
        addTearDown(
          () =>
              binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
        );
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        final container = pushTestContainer(
          session: SessionStore(tokens: pushTestTokens),
          httpClient: _lifecycleRecorder(lifecycleReports),
          channel: ApnsTokenChannel(isIOS: true),
        );

        container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 3));

        expect(lifecycleReports, ['background']);

        container.dispose();
        async.flushMicrotasks();
      });
    });

    test('inactive before the app was ever resumed is not foreground', () {
      fakeAsync((async) {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.resetInternalState();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        addTearDown(
          () =>
              binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
        );
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        final container = pushTestContainer(
          session: SessionStore(tokens: pushTestTokens),
          httpClient: _lifecycleRecorder(lifecycleReports),
          channel: ApnsTokenChannel(isIOS: true),
        );

        container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();
        async.elapse(const Duration(minutes: 3));

        expect(lifecycleReports, ['background']);

        container.dispose();
        async.flushMicrotasks();
      });
    });

    test('inactive after a resume is still foreground (Control Centre)', () {
      fakeAsync((async) {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        final container = pushTestContainer(
          session: SessionStore(tokens: pushTestTokens),
          httpClient: _lifecycleRecorder(lifecycleReports),
          channel: ApnsTokenChannel(isIOS: true),
        );
        container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();

        binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
        async.flushMicrotasks();

        expect(lifecycleReports, [
          'foreground',
        ], reason: 'still foreground, and not worth a second report');

        container.dispose();
        async.flushMicrotasks();
      });
    });

    test('the heartbeat stops reporting once the app is no longer resumed', () {
      fakeAsync((async) {
        final binding = TestWidgetsFlutterBinding.ensureInitialized();
        binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        final container = pushTestContainer(
          session: SessionStore(tokens: pushTestTokens),
          httpClient: _lifecycleRecorder(lifecycleReports),
          channel: ApnsTokenChannel(isIOS: true),
        );
        container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();
        expect(lifecycleReports, ['foreground']);

        binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        async.elapse(const Duration(minutes: 3));

        expect(lifecycleReports, ['foreground', 'background']);

        container.dispose();
        async.flushMicrotasks();
      });
    });

    test('backgrounding stops the heartbeat: it does not go on re-reporting '
        '"foreground" for a screen nobody is looking at', () {
      fakeAsync((async) {
        final lifecycleReports = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );

        final session = SessionStore(tokens: pushTestTokens);
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' &&
                request.url.path == '/push/lifecycle') {
              lifecycleReports.add(
                (jsonDecode(request.body) as Map<String, dynamic>)['state']
                    as String,
              );
            }
            return http.Response('', 204);
          }),
          channel: ApnsTokenChannel(isIOS: true),
        );
        addTearDown(container.dispose);

        final controller = container.read(pushControllerProvider.notifier);
        async.flushMicrotasks();
        expect(lifecycleReports, ['foreground']);

        controller.didChangeAppLifecycleState(AppLifecycleState.paused);
        async.flushMicrotasks();
        expect(lifecycleReports, ['foreground', 'background']);

        async.elapse(const Duration(minutes: 3));

        expect(
          lifecycleReports,
          ['foreground', 'background'],
          reason:
              'the heartbeat must stop with the app, not keep '
              'claiming "foreground" from a paused isolate',
        );

        container.dispose();
        async.flushMicrotasks();
      });
    });
  });
}

/// Records the `state` of every lifecycle report into [reports].
http.Client _lifecycleRecorder(List<String> reports) =>
    MockClient((request) async {
      if (request.method == 'PUT' && request.url.path == '/push/lifecycle') {
        reports.add(
          (jsonDecode(request.body) as Map<String, dynamic>)['state'] as String,
        );
      }
      return http.Response('', 204);
    });

/// A key store whose [delete] always fails, standing in for a storage-layer
/// failure partway through sign-out.
class _DeleteFailingKeyStore implements KeyStore {
  final _inner = InMemoryKeyStore();

  @override
  Future<KeyHandle> put(String name, String secret) => _inner.put(name, secret);

  @override
  Future<String?> read(KeyHandle handle) => _inner.read(handle);

  @override
  Future<void> delete(KeyHandle handle) async =>
      throw StateError('key store unavailable');

  @override
  Future<void> clear() => _inner.clear();

  @override
  Future<List<int>> sign(KeyHandle handle, List<int> payload) =>
      _inner.sign(handle, payload);
}
