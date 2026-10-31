// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared doubles for the push controller tests: the mocked native channels,
/// a container wired the way the app is, and fake FCM and permission sources.
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

const pushChannelName = 'top.npcserver.slimm/push';

void mockPushChannel(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel(pushChannelName), handler);
}

/// flutter_local_notifications' Android implementation sends every call -
/// `createNotificationChannel`, `initialize`, `requestNotificationsPermission`
/// - over this one channel, so mocking it is what lets a
/// [LocalNotifications] with `isAndroid: true` be constructed here without a
/// real device.
const notificationsPluginChannelName =
    'dexterous.com/flutter/local_notifications';

void mockLocalNotificationsPlugin(
  Future<Object?> Function(MethodCall call)? handler,
) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel(notificationsPluginChannelName),
        handler,
      );
}

const pushTestTokens = TokenPair(
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
ProviderContainer pushTestContainer({
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
class FakeFcmTokenSource implements FcmTokenSource {
  FakeFcmTokenSource({this.token, this.error});

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
class ThrowingRefreshFcmTokenSource implements FcmTokenSource {
  @override
  Future<String?> getToken() async => 'unused';

  @override
  Stream<String> get onTokenRefresh =>
      throw StateError('[core/no-app] No Firebase App has been created');
}

/// An [AndroidPermissionRequester] a test fully controls, standing in for
/// the plugin's own Android implementation.
class FakePermissionRequester implements AndroidPermissionRequester {
  FakePermissionRequester({required this.granted});

  final bool granted;

  @override
  Future<bool> requestNotificationsPermission() async => granted;
}
