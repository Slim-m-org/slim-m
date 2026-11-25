// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Push registration state across permission changes, sign-out races, token
/// rotation and backgrounding.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import '../support/push_controller_harness.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  setUpAll(registerAndroidLocalNotificationsPluginForTest);
  setUp(() => SharedPreferences.setMockInitialValues({}));
  tearDown(() => mockPushChannel(null));

  group('iOS notification permission', () {
    test('a denied permission reads as blocked, and a later grant as '
        'registered again without re-registering', () async {
      var authorization = 'denied';
      var puts = 0;
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          'getNotificationAuthorization' => authorization,
          _ => null,
        },
      );
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') puts++;
          return http.Response('', 204);
        }),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);
      final controller = container.read(pushControllerProvider.notifier);
      await pumpEventQueue();

      expect(
        container.read(pushControllerProvider),
        PushStatus.registeredNotificationsBlocked,
      );

      authorization = 'authorized';
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();

      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect(puts, 1);
    });
  });

  group('sign-out during registration', () {
    for (final succeeds in [true, false]) {
      test(
        'a registration that ${succeeds ? 'succeeds' : 'fails'} after '
        'sign-out leaves the status signed out and starts no heartbeat',
        () async {
          final release = Completer<void>();
          var lifecycleCalls = 0;
          mockPushChannel(
            (call) async => switch (call.method) {
              'getToken' => 'abcd1234',
              _ => null,
            },
          );
          final session = SessionStore();
          final container = pushTestContainer(
            session: session,
            httpClient: MockClient((request) async {
              if (request.url.path == '/push/lifecycle') lifecycleCalls++;
              if (request.method == 'PUT' && request.url.path == '/push') {
                await release.future;
                return http.Response('', succeeds ? 204 : 500);
              }
              return http.Response('', 204);
            }),
            channel: ApnsTokenChannel(isIOS: true),
          );
          addTearDown(container.dispose);
          container.read(pushControllerProvider.notifier);
          session.set(pushTestTokens);
          await pumpEventQueue();

          session.set(null);
          await pumpEventQueue();
          release.complete();
          await pumpEventQueue();

          expect(
            container.read(pushControllerProvider),
            PushStatus.notSignedIn,
          );
          expect(lifecycleCalls, 0);
        },
      );
    }
  });

  group('Android blocked notifications', () {
    test('resuming neither re-asks nor re-registers, and a grant made in '
        'system settings is picked up quietly', () async {
      mockLocalNotificationsPlugin((call) async => true);
      addTearDown(() => mockLocalNotificationsPlugin(null));
      var puts = 0;
      final requester = FakePermissionRequester(granted: false);
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') puts++;
          return http.Response('', 204);
        }),
        fcmChannel: FcmTokenChannel(
          source: FakeFcmTokenSource(token: 'fcm-1'),
          isAndroid: true,
        ),
        localNotifications: LocalNotifications(
          isAndroid: true,
          permissionRequester: requester,
        ),
      );
      addTearDown(container.dispose);
      final controller = container.read(pushControllerProvider.notifier);
      await pumpEventQueue();
      expect(
        container.read(pushControllerProvider),
        PushStatus.registeredNotificationsBlocked,
      );
      expect((puts, requester.requests), (1, 1));

      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect((puts, requester.requests), (1, 1));
      expect(
        container.read(pushControllerProvider),
        PushStatus.registeredNotificationsBlocked,
      );

      requester.granted = true;
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(container.read(pushControllerProvider), PushStatus.registered);
      expect((puts, requester.requests), (1, 1));
    });
  });

  group('APNs token rotation', () {
    test(
      'a token that arrives after registration reaches the server',
      () async {
        final tokens = <String>[];
        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'abcd1234',
            _ => null,
          },
        );
        final channel = ApnsTokenChannel(isIOS: true);
        final session = SessionStore(tokens: pushTestTokens);
        final container = pushTestContainer(
          session: session,
          httpClient: MockClient((request) async {
            if (request.method == 'PUT' && request.url.path == '/push') {
              tokens.add(request.body);
            }
            return http.Response('', 204);
          }),
          channel: channel,
        );
        addTearDown(container.dispose);
        container.read(pushControllerProvider.notifier);
        await pumpEventQueue();
        expect(tokens, hasLength(1));

        mockPushChannel(
          (call) async => switch (call.method) {
            'getToken' => 'ffff9999',
            _ => null,
          },
        );
        await channel.debugDeliverToken('ffff9999');
        await pumpEventQueue();

        expect(tokens, hasLength(2));
        expect(tokens.last, contains('ffff9999'));
      },
    );

    test('the same token announced again does not re-register', () async {
      var puts = 0;
      mockPushChannel(
        (call) async => switch (call.method) {
          'getToken' => 'abcd1234',
          _ => null,
        },
      );
      final channel = ApnsTokenChannel(isIOS: true);
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.method == 'PUT' && request.url.path == '/push') puts++;
          return http.Response('', 204);
        }),
        channel: channel,
      );
      addTearDown(container.dispose);
      container.read(pushControllerProvider.notifier);
      await pumpEventQueue();

      await channel.debugDeliverToken('abcd1234');
      await pumpEventQueue();

      expect(puts, 1);
    });
  });

  group('background report', () {
    test('is sent inside a native background task', () async {
      final calls = <String>[];
      mockPushChannel((call) async {
        calls.add(call.method);
        return switch (call.method) {
          'getToken' => 'abcd1234',
          'beginBackgroundTask' => 7,
          _ => null,
        };
      });
      final session = SessionStore(tokens: pushTestTokens);
      final container = pushTestContainer(
        session: session,
        httpClient: MockClient((request) async {
          if (request.url.path == '/push/lifecycle') {
            calls.add('report');
          }
          return http.Response('', 204);
        }),
        channel: ApnsTokenChannel(isIOS: true),
      );
      addTearDown(container.dispose);
      final controller = container.read(pushControllerProvider.notifier);
      await pumpEventQueue();
      calls.clear();

      controller.didChangeAppLifecycleState(AppLifecycleState.hidden);
      await pumpEventQueue();

      expect(calls.where((c) => c != 'getNotificationAuthorization').toList(), [
        'beginBackgroundTask',
        'report',
        'endBackgroundTask',
      ]);
    });
  });
}
