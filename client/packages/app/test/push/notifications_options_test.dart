// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Troubleshooting test notification button on Linux and Android.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/features/settings/widgets/notification_troubleshooting_card.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

class _FakeNotifications implements LocalNotifications {
  /// Posting throws, as it does with no notification daemon on the session bus.
  bool broken = false;
  final shown = <String>[];
  final channels = <LocalAlertChannel>[];

  @override
  Future<void> show(
    String text, {
    required LocalAlertChannel channel,
    String? title,
    String? payload,
    int? id,
  }) async {
    if (broken) throw StateError('no notification daemon');
    shown.add(text);
    channels.add(channel);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  _FakeNotifications notifications,
) async {
  tester.view.physicalSize = const Size(1000, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      localNotificationsProvider.overrideWithValue(notifications),
    ],
  )..read(preferencesProvider);
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: NotificationTroubleshootingCard()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Send test posts a local notification and a confirming toast', (
    tester,
  ) async {
    final notifications = _FakeNotifications();
    final container = await _pump(tester, notifications);

    await tester.ensureVisible(find.text('Send test'));
    await tester.tap(find.text('Send test'));
    await tester.pumpAndSettle();

    expect(notifications.shown.single, startsWith('Test notification'));
    expect(notifications.channels.single, LocalAlertChannel.messages);
    expect(
      container.read(toastsProvider).map((t) => t.message),
      contains('Test notification sent.'),
    );
    final toasts = container.read(toastsProvider.notifier);
    for (final toast in container.read(toastsProvider)) {
      toasts.dismiss(toast.id);
    }
  });

  testWidgets('a notification the OS refuses is not reported as sent', (
    tester,
  ) async {
    final notifications = _FakeNotifications()..broken = true;
    final container = await _pump(tester, notifications);

    await tester.ensureVisible(find.text('Send test'));
    await tester.tap(find.text('Send test'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(container.read(toastsProvider), isEmpty);
    expect(
      find.text(
        'Could not show the test notification. Check that your system allows '
        'notifications from slim-m.',
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Dismiss'));
    await tester.pump();
    expect(find.textContaining('Could not show'), findsNothing);
  });
}
