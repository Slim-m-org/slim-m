// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a desktop banner is filed under, and how a stale or launching one is handled.
library;

import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

class _Plugin implements FlutterLocalNotificationsPlugin {
  NotificationDetails? shown;
  final cancelled = <int>[];
  NotificationAppLaunchDetails? launch;
  InitializationSettings? settings;

  @override
  Future<bool?> initialize(
    InitializationSettings initializationSettings, {
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
        onDidReceiveBackgroundNotificationResponse,
  }) async {
    settings = initializationSettings;
    return true;
  }

  @override
  Future<void> show(
    int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails, {
    String? payload,
  }) async {
    shown = notificationDetails;
  }

  @override
  Future<void> cancel(int id, {String? tag}) async => cancelled.add(id);

  @override
  Future<NotificationAppLaunchDetails?>
      getNotificationAppLaunchDetails() async => launch;

  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(LocalNotifications.resetLaunchPayloadTakenForTest);

  group('Linux banner identity', () {
    test('a message banner names the desktop entry, icon and chat category',
        () async {
      final plugin = _Plugin();
      await LocalNotifications(plugin: plugin, isAndroid: false, isLinux: true)
          .show('hi', channel: LocalAlertChannel.messages);

      final details = plugin.shown!.linux!;
      expect(details.category, LinuxNotificationCategory.imReceived);
      expect(details.customHints!.single.name, 'desktop-entry');
      expect(details.customHints!.single.value.value, linuxDesktopEntry);
      final icon = plugin.settings!.linux!.defaultIcon! as ThemeLinuxIcon;
      expect(icon.name, linuxDesktopEntry);
    });

    test('a call banner is not styled as a chat message', () async {
      final plugin = _Plugin();
      await LocalNotifications(plugin: plugin, isAndroid: false, isLinux: true)
          .show('ring', channel: LocalAlertChannel.calls);

      expect(plugin.shown!.linux!.category, isNull);
    });
  });

  group('retracting banners that were read', () {
    test('Linux cancels each stale id through the plugin', () async {
      final plugin = _Plugin();
      final notifications =
          LocalNotifications(plugin: plugin, isAndroid: false, isLinux: true);
      await notifications.show('a',
          channel: LocalAlertChannel.messages, id: 1001);
      await notifications.show('b',
          channel: LocalAlertChannel.messages, id: 2002);
      await notifications.cancelShown({1001, 2002});

      expect(plugin.cancelled, unorderedEquals([1001, 2002]));
    });

    test('Windows removes each stale toast by tag through the runner',
        () async {
      final calls = <MethodCall>[];
      const channel = MethodChannel('test/windows_toasts');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return true;
      });
      addTearDown(() => TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null));
      final plugin = _Plugin();

      final notifications = LocalNotifications(
        plugin: plugin,
        isAndroid: false,
        isLinux: false,
        isWindows: true,
        windowsToasts: channel,
      );
      await notifications.show('a', channel: LocalAlertChannel.messages, id: 7);
      calls.clear();
      await notifications.cancelShown({7});

      expect(calls.single.arguments, containsPair('tag', '7'));
      expect(plugin.cancelled, isEmpty);
    });
  });

  group('the click that started the process', () {
    test('Windows hands back the payload of the toast that launched it',
        () async {
      final plugin = _Plugin()
        ..launch = const NotificationAppLaunchDetails(
          true,
          notificationResponse: NotificationResponse(
            notificationResponseType:
                NotificationResponseType.selectedNotification,
            payload: 'where',
          ),
        );

      final payload = await LocalNotifications(
        plugin: plugin,
        isAndroid: false,
        isLinux: false,
        isWindows: true,
      ).launchPayload();

      expect(payload, 'where');
    });

    test('Linux has no launching click to hand back', () async {
      final plugin = _Plugin()
        ..launch = const NotificationAppLaunchDetails(true);

      expect(
        await LocalNotifications(
                plugin: plugin, isAndroid: false, isLinux: true)
            .launchPayload(),
        isNull,
      );
    });
  });
}
