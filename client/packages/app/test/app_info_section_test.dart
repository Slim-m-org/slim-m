// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `AppInfoSection` used to render its Version and Debug log rows as bare
/// `ListTile`s, the taller, differently-inset row the design system's own
/// font-fix commit named as a defect (#477) but did not itself convert.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/auto_update_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/app_info_section.dart';
import 'package:slimm_app/src/widgets/whats_new_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'settings_harness.dart';

void main() {
  setUpAll(mockAppVersion);

  testWidgets('the App group is AppListRow throughout, never a bare ListTile', (
    tester,
  ) async {
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    await tester.tap(find.text('About slim-m'));
    await tester.pumpAndSettle();

    expect(find.byType(ListTile), findsNothing);
    expect(find.text('slim-m'), findsWidgets);
    expect(find.textContaining('Version 0.1.0'), findsOneWidget);
    expect(find.text('Release notes'), findsOneWidget);
  });

  Future<void> pumpAbout(WidgetTester tester, String buildNumber) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          appInfoProvider.overrideWith(
            (ref) async => PackageInfo(
              appName: 'slim-m',
              packageName: 'top.npcserver.slimm',
              version: '0.89.0',
              buildNumber: buildNumber,
            ),
          ),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: SingleChildScrollView(child: AppInfoSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the Updates rows start their text in one column', (
    tester,
  ) async {
    await pumpAbout(tester, '');

    final xs = {
      for (final label in ['Automatic updates', 'Release notes'])
        label: tester.getTopLeft(find.text(label)).dx,
    };
    expect(xs.values.toSet(), hasLength(1), reason: '$xs');
  });

  testWidgets('the Release notes row opens the full history', (tester) async {
    await pumpAbout(tester, '');

    await tester.tap(find.text('Release notes'));
    await tester.pumpAndSettle();

    expect(find.byKey(whatsNewBodyBoxKey), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
  });

  testWidgets('a build with no build number shows the bare version', (
    tester,
  ) async {
    await pumpAbout(tester, '');

    expect(find.text('Version 0.89.0'), findsOneWidget);
    expect(find.textContaining('()'), findsNothing);
  });

  testWidgets('a build number is shown in parentheses after the version', (
    tester,
  ) async {
    await pumpAbout(tester, '42');

    expect(find.text('Version 0.89.0 (42)'), findsOneWidget);
  });

  /// Decision 0025: the switch that decides whether the splash installs an
  /// update on each launch lives here, because About is where the version it
  /// would change is already shown.
  testWidgets('automatic updates is a switch here, and moving it persists', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await pumpPersonalSettings(tester, 0, scrollToBottom: false);

    await tester.tap(find.text('About slim-m'));
    await tester.pumpAndSettle();

    expect(find.text('Automatic updates'), findsOneWidget);
    final toggle = find.byType(AppToggle);
    expect(
      tester.widget<AppToggle>(toggle).value,
      isTrue,
      reason: 'a fresh install is opted in (decision 0025 addendum)',
    );

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    expect(
      (await SharedPreferences.getInstance()).getBool(autoUpdateKey),
      isFalse,
    );
  });

  test('the switch says what it does for this install format', () {
    expect(
      automaticUpdatesDescription(InstallFormat.rpm),
      contains('package manager'),
    );
    expect(
      automaticUpdatesDescription(InstallFormat.tarball),
      contains('Tell me'),
    );
  });
}
