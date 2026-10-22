// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// There is no General pane: the desktop startup rows live in the Desktop
/// pane, and message page size lives in Media and cache. Phone width
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
import 'package:slimm_app/src/features/settings/widgets/desktop_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_status_sections.dart';
import 'package:slimm_app/src/routing/routes.dart' show desktopPane;
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

  testWidgets('the startup rows share one Startup card in the Desktop pane', (
    tester,
  ) async {
    await pumpSection(
      tester,
      const DesktopSettingsSection(),
      overrides: [autostartProvider.overrideWith((ref) async => _Autostart())],
    );

    expect(find.text('Startup'), findsOneWidget);
    expect(find.text('Start on login'), findsOneWidget);
    expect(find.text('Startup splash'), findsOneWidget);
  });

  testWidgets('the startup rows are gone from Appearance and Notifications', (
    tester,
  ) async {
    await pumpSection(
      tester,
      const Column(
        children: [AppearanceSettingsSection(), NotificationsSection()],
      ),
      overrides: [autostartProvider.overrideWith((ref) async => _Autostart())],
    );

    expect(find.text('Startup splash'), findsNothing);
    expect(find.text('Start on login'), findsNothing);
  });

  testWidgets('the Desktop pane is in the nav on a desktop host', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(
      tester,
      0,
      scrollToBottom: false,
      hasDesktopPane: true,
    );
    expect(find.text('Desktop'), findsOneWidget);
  });

  testWidgets('a phone host has no Desktop pane', (tester) async {
    useTallViewport(tester);
    await pumpPersonalSettings(
      tester,
      0,
      scrollToBottom: false,
      hasDesktopPane: false,
    );
    expect(find.text('Desktop'), findsNothing);
  });

  testWidgets('phone width drills into Desktop and finds the startup rows', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 2400);
    addTearDown(tester.view.reset);
    await pumpPersonalSettings(
      tester,
      0,
      scrollToBottom: false,
      hasDesktopPane: true,
    );
    expect(find.text('Startup splash'), findsNothing);
    await tester.tap(find.text('Desktop'));
    await tester.pumpAndSettle();
    expect(find.text('Startup splash'), findsOneWidget);
  });

  test('search finds splash and start on login in the Desktop pane', () {
    final byLabel = {for (final e in personalSettingsIndex) e.label: e};
    for (final label in ['Startup splash', 'Start on login']) {
      expect(byLabel[label]?.pane, desktopPane, reason: label);
    }
    expect(byLabel['Start on login']?.keywords, contains('autostart'));
    expect(byLabel['Startup splash']?.keywords, contains('launch'));
    expect(personalSettingsIndex.where((e) => e.pane == 'general'), isEmpty);
    final hits = searchSettings('boot', personalSettingsIndex);
    expect(
      hits.map((e) => (e.label, e.pane)),
      contains(('Start on login', desktopPane)),
    );
  });

  testWidgets('choosing a page size persists it', (tester) async {
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
