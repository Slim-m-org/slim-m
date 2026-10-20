// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Notifications pane rows that had no operating test: the dock module
/// sounds toggle and the Linux/Android test notification button.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/modules/providers/module_sound_settings.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/push_controller.dart';
import 'package:slimm_app/src/providers/toasts.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

class _FakeNotifications implements LocalNotifications {
  final shown = <String>[];
  final channels = <LocalAlertChannel>[];

  @override
  Future<void> show(
    String text, {
    required LocalAlertChannel channel,
    String? title,
    String? payload,
  }) async {
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
          body: SingleChildScrollView(child: NotificationsSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('the dock module sounds toggle persists, both ways', (
    tester,
  ) async {
    final container = await _pump(tester, _FakeNotifications());
    final toggle = find.byWidgetPredicate(
      (w) =>
          w is AppToggle && w.semanticLabel == 'Let modules play sound effects',
    );
    expect(container.read(moduleSoundSettingsProvider), isTrue);

    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(container.read(moduleSoundSettingsProvider), isFalse);
    expect(prefs.getBool(moduleSoundEnabledKey), isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(prefs.getBool(moduleSoundEnabledKey), isTrue);
  });

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
}
