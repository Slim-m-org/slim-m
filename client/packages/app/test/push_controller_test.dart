// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for push registration: gated on a session, tracked as an honest
/// status rather than swallowed silence, and retried on resume and on a
/// session already signed in when the controller is created (a restored
/// session never passes through the sign-in screen that would otherwise
/// have kicked it off).
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'support/fake_api.dart';

const _channelName = 'top.npcserver.slimm/push';

void _mock(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(_channelName), handler);
}

/// flutter_local_notifications' Android implementation sends every call -
/// `createNotificationChannel`, `initialize`, `requestNotificationsPermission`
/// - over this one channel, so mocking it is what lets a
/// [LocalNotifications] with `isAndroid: true` be constructed here without a
/// real device.
const _notificationsPluginChannelName =
    'dexterous.com/flutter/local_notifications';

void _mockLocalNotificationsPlugin(
  Future<Object?> Function(MethodCall call)? handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel(_notificationsPluginChannelName),
        handler,
      );
}

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A container wired the way the app is: a real session and key store, with
/// only the network and the native push channels swapped for test doubles.
///
/// Neither push channel needs overriding to stand in for "this is neither
/// iOS nor Android": the test runner is never actually either, so the real
/// default [ApnsTokenChannel] and [FcmTokenChannel] both already report
/// `Unsupported` on their own, exactly as they would on Linux desktop.
ProviderContainer _container({
  required http.Client httpClient,
  SessionStore? session,
  ApnsTokenChannel? channel,
  FcmTokenChannel? fcmChannel,
  LocalNotifications? localNotifications,
}) {
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (session != null) sessionProvider.overrideWithValue(session),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        );
        ref.onDispose(api.close);
        return api;
      }),
      if (channel != null) apnsTokenChannelProvider.overrideWithValue(channel),
      if (fcmChannel != null)
        fcmTokenChannelProvider.overrideWithValue(fcmChannel),
      if (localNotifications != null)
        localNotificationsProvider.overrideWithValue(localNotifications),
    ],
  );
}

/// A [FcmTokenSource] a test fully controls: either a fixed token or a
/// thrown error, plus a rotation stream the test drives by hand.
class _FakeFcmTokenSource implements FcmTokenSource {
  _FakeFcmTokenSource({this.token, this.error});

  final String? token;
  final Object? error;
  final _refreshController = StreamController<String>.broadcast();

  @override
  Future<String?> getToken() async {
    if (error != null) throw error!;
    return token;
  }

  @override
  Stream<String> get onTokenRefresh => _refreshController.stream;

  void rotate(String newToken) => _refreshController.add(newToken);
}

/// An [FcmTokenSource] whose rotation stream throws the moment it is asked
/// for, rather than ever handing back a [Stream] - standing in for
/// [FirebaseMessaging.instance] throwing `[core/no-app]` synchronously when
/// no default Firebase app exists (an Android build with no
/// `google-services.json`; see `android/app/build.gradle.kts`).
class _ThrowingRefreshFcmTokenSource implements FcmTokenSource {
  @override
  Future<String?> getToken() async => 'unused';

  @override
  Stream<String> get onTokenRefresh =>
      throw StateError('[core/no-app] No Firebase App has been created');
}

/// An [AndroidPermissionRequester] a test fully controls, standing in for
/// the plugin's own Android implementation.
class _FakePermissionRequester implements AndroidPermissionRequester {
  _FakePermissionRequester({required this.granted});

  final bool granted;

  @override
  Future<bool> requestNotificationsPermission() async => granted;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        channel: ApnsTokenChannel(isIOS: true),
        fcmChannel: FcmTokenChannel(
          source: _ThrowingRefreshFcmTokenSource(),
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
      final container = _container(
        httpClient: MockClient((_) async => http.Response('unused', 500)),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.notSignedIn);
    });

    test('a server failure never propagates out of register()', () async {
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
  });

  group('push status transitions', () {
    test('unsupported platform is reported, not a silent no-token', () async {
      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
        _mock(null);
        final session = SessionStore(tokens: _tokens);
        final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getRegistrationError' => 'denied',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(null);
      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(container.read(pushControllerProvider), PushStatus.registered);
    });

    test('resuming does not retry once already registered', () async {
      var registerPushCalls = 0;
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      /// Starts signed out, so touching the notifier below does not also fire
      /// the constructor's own already-signed-in registration attempt
      /// alongside this test's: signing in afterwards is the single, clean
      /// trigger this test counts against.
      final session = SessionStore();
      final container = _container(
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
      session.set(_tokens);
      await pumpEventQueue();
      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(registerPushCalls, 1);

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      // Already registered, so resuming must not re-hit the server.
      expect(registerPushCalls, 1);
    });

    test('signing out resets status to notSignedIn', () async {
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => () {
            getTokenCalls++;
            return 'abcd1234';
          }(),
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
      _mock(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      addTearDown(() => _mock(null));

      /// Already signed in at construction, so touching the notifier below
      /// also fires the constructor's own already-signed-in attempt: a third,
      /// uncoordinated caller alongside the two explicit ones.
      final session = SessionStore(tokens: _tokens);
      final container = _container(
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
        final session = SessionStore(tokens: _tokens);
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

  group('Android push', () {
    test('an FCM token accepted by the server registers as android', () async {
      Map<String, dynamic>? sentBody;
      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return http.Response('', 204);
        }),
        fcmChannel: FcmTokenChannel(
          source: _FakeFcmTokenSource(token: 'fcm-token-1'),
          isAndroid: true,
        ),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();

      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(sentBody, isNotNull);
      expect(sentBody!['platform'], 'android');
      expect(sentBody!['push_token'], 'fcm-token-1');
    });

    test(
      'FCM producing no token is reported as a registration failure',
      () async {
        final session = SessionStore(tokens: _tokens);
        final container = _container(
          session: session,
          httpClient: MockClient((_) async => http.Response('unused', 500)),
          fcmChannel: FcmTokenChannel(
            source: _FakeFcmTokenSource(error: StateError('no Play Services')),
            isAndroid: true,
          ),
        );
        addTearDown(container.dispose);

        await container.read(pushControllerProvider.notifier).register();

        expect(
          container.read(pushControllerProvider),
          PushStatus.registrationFailed,
        );
      },
    );

    test('a rotated FCM token re-registers even though already registered - '
        'unlike an iOS resume, which skips work once registered', () async {
      var registerPushCalls = 0;
      final requests = <Map<String, dynamic>>[];
      final source = _FakeFcmTokenSource(token: 'fcm-token-1');
      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            registerPushCalls++;
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
          }
          return http.Response('', 204);
        }),
        fcmChannel: FcmTokenChannel(source: source, isAndroid: true),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();
      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(registerPushCalls, 1);

      source.rotate('fcm-token-2');
      await pumpEventQueue();

      expect(
        registerPushCalls,
        2,
        reason:
            'a rotated token left unregistered is a device that '
            'silently stops receiving push',
      );
      expect(requests[1]['push_token'], 'fcm-token-2');
      expect(requests[1]['platform'], 'android');
      expect(container.read(pushControllerProvider), PushStatus.registered);
    });

    test(
      'a token rotation while signed out never reaches the server',
      () async {
        var registerPushCalls = 0;
        final source = _FakeFcmTokenSource(token: 'fcm-token-1');
        // Starts signed out; nothing here ever calls register() explicitly.
        final container = _container(
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/push') {
              registerPushCalls++;
            }
            return http.Response('', 204);
          }),
          fcmChannel: FcmTokenChannel(source: source, isAndroid: true),
        );
        addTearDown(container.dispose);

        // Touching the notifier is what starts the refresh subscription.
        container.read(pushControllerProvider.notifier);
        source.rotate('fcm-token-2');
        await pumpEventQueue();

        expect(registerPushCalls, 0);
        expect(container.read(pushControllerProvider), PushStatus.notSignedIn);
      },
    );

    test(
      'a rotation that lands while a registration is already in flight is '
      'not dropped: the server ends up with the rotated token instead of '
      'this device going dead until something unrelated re-registers it',
      () async {
        final firstRequestReceived = Completer<void>();
        final releaseFirstResponse = Completer<void>();
        final requests = <Map<String, dynamic>>[];
        var putCalls = 0;
        final source = _FakeFcmTokenSource(token: 'fcm-token-1');

        final container = _container(
          session: SessionStore(tokens: _tokens),
          httpClient: MockClient((request) async {
            if (request.method != 'PUT' || request.url.path != '/push') {
              return http.Response('', 204);
            }
            putCalls++;
            requests.add(jsonDecode(request.body) as Map<String, dynamic>);
            if (putCalls == 1) {
              firstRequestReceived.complete();
              await releaseFirstResponse.future;
            }
            return http.Response('', 204);
          }),
          fcmChannel: FcmTokenChannel(source: source, isAndroid: true),
        );
        addTearDown(container.dispose);

        // Already signed in, so constructing the controller starts the first
        // registration on its own.
        container.read(pushControllerProvider.notifier);
        await firstRequestReceived.future;

        // The token rotates while that first PUT is still in flight, and
        // unresolved.
        source.rotate('fcm-token-2');
        await pumpEventQueue();
        expect(
          putCalls,
          1,
          reason:
              'a rotation landing mid-registration must queue behind '
              'it, not race it with a second concurrent PUT',
        );

        releaseFirstResponse.complete();
        await pumpEventQueue();
        await pumpEventQueue();

        expect(
          putCalls,
          2,
          reason:
              'the rotated token must still reach the server as its '
              'own follow-up request once the in-flight one clears',
        );
        expect(requests[1]['push_token'], 'fcm-token-2');
        expect(requests[1]['platform'], 'android');
        expect(container.read(pushControllerProvider), PushStatus.registered);
      },
    );

    test('Android notification permission denied is reported honestly, not '
        'as a plain "registered" the settings screen would have to take on '
        'faith', () async {
      _mockLocalNotificationsPlugin((call) async => true);
      addTearDown(() => _mockLocalNotificationsPlugin(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        fcmChannel: FcmTokenChannel(
          source: _FakeFcmTokenSource(token: 'fcm-token-1'),
          isAndroid: true,
        ),
        localNotifications: LocalNotifications(
          isAndroid: true,
          permissionRequester: _FakePermissionRequester(granted: false),
        ),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();

      expect(
        container.read(pushControllerProvider),
        PushStatus.registeredNotificationsBlocked,
      );
    });

    test('Android notification permission granted registers normally, not '
        'downgraded just because the question was asked', () async {
      _mockLocalNotificationsPlugin((call) async => true);
      addTearDown(() => _mockLocalNotificationsPlugin(null));

      final session = SessionStore(tokens: _tokens);
      final container = _container(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        fcmChannel: FcmTokenChannel(
          source: _FakeFcmTokenSource(token: 'fcm-token-1'),
          isAndroid: true,
        ),
        localNotifications: LocalNotifications(
          isAndroid: true,
          permissionRequester: _FakePermissionRequester(granted: true),
        ),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();

      expect(container.read(pushControllerProvider), PushStatus.registered);
    });
  });

  group('foreground lifecycle heartbeat', () {
    test('a foregrounded app keeps re-reporting on its own, so staying on '
        'one screen for minutes never crosses the server\'s one-minute '
        'staleness window and starts a notification for the exact screen '
        'already in front of the user', () {
      fakeAsync((async) {
        final lifecycleReports = <String>[];
        _mock(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );

        final session = SessionStore(tokens: _tokens);
        final container = _container(
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

    test('backgrounding stops the heartbeat: it does not go on re-reporting '
        '"foreground" for a screen nobody is looking at', () {
      fakeAsync((async) {
        final lifecycleReports = <String>[];
        _mock(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );

        final session = SessionStore(tokens: _tokens);
        final container = _container(
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
