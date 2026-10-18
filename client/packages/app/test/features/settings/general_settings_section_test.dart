// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// General holds only the desktop startup rows; message page size lives in
/// Media and cache with the other things this device keeps around. Phone width
/// is desktop-vs-mobile rule 1: the nav drills down to a pane below kCompactWidth.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/messages/providers/message_page_size.dart';
import 'package:slimm_app/src/features/settings/widgets/general_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/performance_settings_section.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_select_row.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_harness.dart';

void main() {
  setUpAll(mockAppVersion);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  Future<void> pumpSection(WidgetTester tester, Widget section) async {
    tester.view.physicalSize = const Size(1000, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(body: SingleChildScrollView(child: section)),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('General is only the startup rows', (tester) async {
    await pumpSection(tester, const GeneralSettingsSection());

    expect(find.text('Startup splash'), findsOneWidget);
    expect(find.text('Message page size'), findsNothing);
    expect(find.text('Run setup again'), findsNothing);
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

  testWidgets('phone: Media and cache holds page size, General the startup', (
    tester,
  ) async {
    useTallViewport(tester);
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    await tester.tap(find.text('Media and cache'));
    await tester.pumpAndSettle();
    expect(find.text('Image cache'), findsOneWidget);
    expect(find.text('Message page size'), findsOneWidget);
    expect(find.text('Startup splash'), findsNothing);

    await tester.tap(find.byTooltip('Back to settings'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('General'));
    await tester.pumpAndSettle();
    expect(find.text('Startup splash'), findsOneWidget);
    expect(find.text('Message page size'), findsNothing);
  });
}
