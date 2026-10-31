// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Android push registration: FCM tokens, rotation, and the notification
/// permission, split from push_controller_test.dart.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'support/push_controller_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  setUpAll(registerAndroidLocalNotificationsPluginForTest);
  // Every registration now reads the content-preview setting, which needs it.
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('Android push', () {
    test('an FCM token accepted by the server registers as android', () async {
      Map<String, dynamic>? sentBody;
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') {
            sentBody = jsonDecode(request.body) as Map<String, dynamic>;
          }
          return http.Response('', 204);
        }),
        fcmChannel: FcmTokenChannel(
          source: FakeFcmTokenSource(token: 'fcm-token-1'),
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
        final session = SessionStore(tokens: pushTestTokens);
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((_) async => http.Response('unused', 500)),
          fcmChannel: FcmTokenChannel(
            source: FakeFcmTokenSource(error: StateError('no Play Services')),
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
      final source = FakeFcmTokenSource(token: 'fcm-token-1');
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
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
        final source = FakeFcmTokenSource(token: 'fcm-token-1');
        // Starts signed out; nothing here ever calls register() explicitly.
        final container = pushTestContainer(
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
        final source = FakeFcmTokenSource(token: 'fcm-token-1');

        final container = pushTestContainer(
          session: SessionStore(tokens: pushTestTokens),
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

        // Already signed in, so construction starts the first registration itself.
        container.read(pushControllerProvider.notifier);
        await firstRequestReceived.future;

        // The token rotates while that first PUT is still in flight.
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
      mockLocalNotificationsPlugin((call) async => true);
      addTearDown(() => mockLocalNotificationsPlugin(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        fcmChannel: FcmTokenChannel(
          source: FakeFcmTokenSource(token: 'fcm-token-1'),
          isAndroid: true,
        ),
        localNotifications: LocalNotifications(
          isAndroid: true,
          permissionRequester: FakePermissionRequester(granted: false),
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
      mockLocalNotificationsPlugin((call) async => true);
      addTearDown(() => mockLocalNotificationsPlugin(null));

      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((_) async => http.Response('', 204)),
        fcmChannel: FcmTokenChannel(
          source: FakeFcmTokenSource(token: 'fcm-token-1'),
          isAndroid: true,
        ),
        localNotifications: LocalNotifications(
          isAndroid: true,
          permissionRequester: FakePermissionRequester(granted: true),
        ),
      );
      addTearDown(container.dispose);

      await container.read(pushControllerProvider.notifier).register();

      expect(container.read(pushControllerProvider), PushStatus.registered);
    });
  });
}
