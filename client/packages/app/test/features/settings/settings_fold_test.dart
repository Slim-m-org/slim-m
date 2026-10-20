// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// There is no General pane: the desktop startup rows live with the scope
/// they describe, and message page size lives in Media and cache. Phone width
/// is desktop-vs-mobile rule 1: the nav drills down to a pane below kCompactWidth.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/message_page_size.dart';
import 'package:slimm_app/src/features/settings/providers/autostart_setting.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/widgets/appearance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_app/src/features/settings/widgets/performance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart' show Autostart;

import 'settings_harness.dart';

class _Autostart implements Autostart {
  @override
  Future<void> repair() async {}

  @override
  Future<bool> isEnabled() async => false;

  @override
  Future<void> setEnabled(bool on) async {}
}

void main() {
  setUpAll(mockAppVersion);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSection(
    WidgetTester tester,
    Widget section, {
    List<Override> overrides = const [],
  }) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: overrides,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: SingleChildScrollView(child: section)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('startup splash is an Appearance row, not a pane of its own', (
    tester,
  ) async {
    await pumpSection(tester, const AppearanceSettingsSection());

    expect(find.text('Startup splash'), findsOneWidget);
  });

  testWidgets('start on login sits with Notifications', (tester) async {
    await pumpSection(
      tester,
      const NotificationsSection(),
      overrides: [autostartProvider.overrideWith((ref) async => _Autostart())],
    );

    expect(find.text('Start on login'), findsOneWidget);
  });

  test('search finds splash and start on login in their new panes', () {
    final byLabel = {for (final e in personalSettingsIndex) e.label: e.pane};
    expect(byLabel['Startup splash'], 'appearance');
    expect(byLabel['Start on login'], 'notifications');
    expect(personalSettingsIndex.where((e) => e.pane == 'general'), isEmpty);
  });

  testWidgets('page size sits in Media and cache and persists', (tester) async {
    await pumpSection(tester, const PerformanceSettingsSection());

    await tester.tap(find.byType(SettingsSelectRow<MessagePageSize>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(MessagePageSize.large.label));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString(messagePageSizeKey), 'large');
  });

  testWidgets('phone: no General row, page size stays in Media and cache', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    expect(find.text('General'), findsNothing);
    await tester.tap(find.text('Media and cache'));
    await tester.pumpAndSettle();
    expect(find.text('Message page size'), findsOneWidget);
  });
}
