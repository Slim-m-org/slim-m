// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the local-notification seam: the versioned channel constants,
/// that a non-Android platform never touches the plugin, and that
/// permission is requested (and only requested) from [requestPermission],
/// never as a side effect of [LocalNotifications.show] - the call FCM's
/// Activity-less background isolate makes for every backgrounded push.
library;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

/// The channel flutter_local_notifications' Android implementation sends
/// every call over - `initialize`, `createNotificationChannel`,
/// `requestNotificationsPermission`, `show`, all of it - so mocking this one
/// channel is what lets a test drive [LocalNotifications] on a simulated
/// Android without a real device.
const _pluginChannelName = 'dexterous.com/flutter/local_notifications';

void _mockPlugin(Future<Object?> Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel(_pluginChannelName), handler);
}

class _SpyPlugin implements FlutterLocalNotificationsPlugin {
  DidReceiveNotificationResponseCallback? onResponse;

  @override
  Future<bool?> initialize(
    InitializationSettings initializationSettings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    onResponse = onDidReceiveNotificationResponse;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(registerAndroidLocalNotificationsPluginForTest);

  group('channel constants', () {
    test('the messages channel id carries an explicit version', () {
      // A version bump means a new id: Android forbids editing an existing one.
      expect(messagesChannelId, 'messages_v1');
    });

    test('the mentions channel id carries its own, independent version', () {
      expect(mentionsChannelId, 'mentions_v1');
    });

    test('messages and mentions are two channels, not one shared id', () {
      // Sharing an id would make "buzz for one, not the other" unreachable.
      expect(
          LocalAlertChannel.messages.id, isNot(LocalAlertChannel.mentions.id));
    });

    test('messages and mentions post to two distinct notification ids', () {
      // Otherwise whichever of the two arrived first would be silently dropped.
      expect(
        LocalAlertChannel.messages.notificationId,
        isNot(LocalAlertChannel.mentions.notificationId),
      );
    });

    test('the security channel is versioned and has its own ids', () {
      expect(securityChannelId, 'security_v1');
      final others = LocalAlertChannel.values
          .where((c) => c != LocalAlertChannel.security);
      expect(others.map((c) => c.id), isNot(contains(securityChannelId)));
      expect(
        others.map((c) => c.notificationId),
        isNot(contains(LocalAlertChannel.security.notificationId)),
      );
    });
  });

  group('clicking a notification', () {
    test('Linux registers a response callback that reports the activation',
        () async {
      final spy = _SpyPlugin();
      var activations = 0;
      String? seen;
      final notifications = LocalNotifications(
        plugin: spy,
        isAndroid: false,
        isLinux: true,
        onActivated: (payload) async {
          activations++;
          seen = payload;
        },
      );
      await notifications.show('New message',
          channel: LocalAlertChannel.messages, payload: 'where');

      expect(spy.onResponse, isNotNull);
      spy.onResponse!(
        const NotificationResponse(
          notificationResponseType:
              NotificationResponseType.selectedNotification,
          payload: 'where',
        ),
      );
      expect(activations, 1);
      expect(seen, 'where');
    });
  });

  group('LocalNotifications.show', () {
    test('a fully unsupported platform never touches the plugin', () async {
      // iOS/web/macOS/Windows: no mock handler is installed, so a call
      // reaching the plugin would throw MissingPluginException; completing
      // proves the platform gate ran first.
      final notifications =
          LocalNotifications(isAndroid: false, isLinux: false);

      await expectLater(
        notifications.show('New message', channel: LocalAlertChannel.messages),
        completes,
      );
    });

    test('Linux initializes and posts through the plugin, with no channels',
        () async {
      final calledMethods = <String>[];
      _mockPlugin((call) async {
        calledMethods.add(call.method);
        return true;
      });
      addTearDown(() => _mockPlugin(null));

      final notifications = LocalNotifications(isAndroid: false, isLinux: true);
      await notifications.show('New message',
          channel: LocalAlertChannel.messages);

      expect(calledMethods, contains('initialize'));
      expect(calledMethods, contains('show'));
      expect(
        calledMethods,
        isNot(contains('createNotificationChannel')),
        reason: 'channels are an Android concept; Linux has none',
      );
    });

    test(
        'never requests notification permission as a side effect - only '
        'requestPermission does, and show is exactly what runs in FCM\'s '
        'Activity-less background isolate for every backgrounded push',
        () async {
      final calledMethods = <String>[];
      _mockPlugin((call) async {
        calledMethods.add(call.method);
        return true;
      });
      addTearDown(() => _mockPlugin(null));

      final notifications = LocalNotifications(isAndroid: true);
      await notifications.show('New message',
          channel: LocalAlertChannel.messages);

      expect(
        calledMethods,
        isNot(contains('requestNotificationsPermission')),
        reason: 'requesting permission from here throws in a background '
            'isolate with no Activity, silently dropping every '
            'backgrounded notification - the entire point of push',
      );
    });

    test('creates every channel, not only the one it is about to post to',
        () async {
      final createdChannelIds = <String>[];
      _mockPlugin((call) async {
        if (call.method == 'createNotificationChannel') {
          final args = call.arguments as Map<Object?, Object?>;
          createdChannelIds.add(args['id'] as String);
        }
        return true;
      });
      addTearDown(() => _mockPlugin(null));

      final notifications = LocalNotifications(isAndroid: true);
      await notifications.show('You were mentioned',
          channel: LocalAlertChannel.mentions);

      expect(
        createdChannelIds,
        containsAll([messagesChannelId, mentionsChannelId, securityChannelId]),
        reason: 'idempotent readiness creates the whole channel set up '
            'front rather than lazily per kind, so a first-ever mention '
            'never races a channel that has not been created yet',
      );
    });

    test('posts a mention on its own channel and notification id', () async {
      final shows = <MethodCall>[];
      _mockPlugin((call) async {
        if (call.method == 'show') shows.add(call);
        return true;
      });
      addTearDown(() => _mockPlugin(null));

      final notifications = LocalNotifications(isAndroid: true);
      await notifications.show('You were mentioned',
          channel: LocalAlertChannel.mentions);

      expect(shows, hasLength(1));
      final args = shows.single.arguments as Map<Object?, Object?>;
      expect(args['id'], LocalAlertChannel.mentions.notificationId);
      final platformSpecifics =
          args['platformSpecifics'] as Map<Object?, Object?>;
      expect(platformSpecifics['channelId'], mentionsChannelId);
    });
  });

  group('LocalNotifications.requestPermission', () {
    test(
        'is a no-op true on a non-Android platform, touching neither the '
        'plugin nor a requester', () async {
      final requester = _FakePermissionRequester(granted: false);
      final notifications = LocalNotifications(
        isAndroid: false,
        permissionRequester: requester,
      );

      final granted = await notifications.requestPermission();

      expect(granted, isTrue);
      expect(requester.calls, 0);
    });

    test('reports true when the requester grants it', () async {
      _mockPlugin((call) async => true);
      addTearDown(() => _mockPlugin(null));
      final requester = _FakePermissionRequester(granted: true);

      final notifications = LocalNotifications(
        isAndroid: true,
        permissionRequester: requester,
      );
      final granted = await notifications.requestPermission();

      expect(granted, isTrue);
      expect(requester.calls, 1);
    });

    test(
        'reports false when the requester denies it, rather than assuming '
        'a token means notifications will show', () async {
      _mockPlugin((call) async => true);
      addTearDown(() => _mockPlugin(null));
      final requester = _FakePermissionRequester(granted: false);

      final notifications = LocalNotifications(
        isAndroid: true,
        permissionRequester: requester,
      );
      final granted = await notifications.requestPermission();

      expect(granted, isFalse);
      expect(requester.calls, 1);
    });
  });
}

/// An [AndroidPermissionRequester] a test fully controls, standing in for
/// the plugin's own Android implementation.
class _FakePermissionRequester implements AndroidPermissionRequester {
  _FakePermissionRequester({required this.granted});

  final bool granted;
  int calls = 0;

  @override
  Future<bool> requestNotificationsPermission() async {
    calls++;
    return granted;
  }
}
