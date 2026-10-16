// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The three rows #38 added to Appearance: the clock's 12/24-hour format, an
/// in-app reduce-motion override, and the high-contrast toggle. Each has to
/// be proven reachable by tapping it, the same property
/// `theme_preference_test.dart` proves for the Theme row above them, since
/// driving the controller directly would prove nothing about whether the row
/// is wired to anything.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/display_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

ProviderContainer _container() {
  final container = ProviderContainer(
    overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pumpSection(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: ListView(children: const [AppearanceSettingsSection()]),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _chooseFrom<T>(WidgetTester tester, String label) async {
  await tester.ensureVisible(find.byType(SettingsSelectRow<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.byType(SettingsSelectRow<T>));
  await tester.pumpAndSettle();
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('picking 24-hour is what actually changes the clock '
      'controller', (tester) async {
    final container = _container();
    await container.read(timeFormatControllerProvider.notifier).restore();
    await _pumpSection(tester, container);

    expect(
      container.read(timeFormatControllerProvider),
      TimeFormatPreference.system,
    );

    await _chooseFrom<TimeFormatPreference>(tester, '24-hour');

    expect(
      container.read(timeFormatControllerProvider),
      TimeFormatPreference.h24,
    );
    expect(find.text('24-hour'), findsOneWidget);
  });

  testWidgets('picking always-reduce is what actually changes the motion '
      'controller', (tester) async {
    final container = _container();
    await container.read(motionPreferenceControllerProvider.notifier).restore();
    await _pumpSection(tester, container);

    await _chooseFrom<MotionOverride>(tester, 'Always reduce');

    expect(
      container.read(motionPreferenceControllerProvider),
      MotionOverride.alwaysReduce,
    );
  });

  testWidgets('the high-contrast toggle is what actually changes the '
      'controller, in both directions', (tester) async {
    final container = _container();
    await container.read(highContrastControllerProvider.notifier).restore();
    await _pumpSection(tester, container);

    expect(container.read(highContrastControllerProvider), isFalse);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(container.read(highContrastControllerProvider), isTrue);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    expect(container.read(highContrastControllerProvider), isFalse);
  });
}
