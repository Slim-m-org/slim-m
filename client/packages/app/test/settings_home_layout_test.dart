// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Settings home: on a phone the search field sits right under the app
/// bar and Sign out is the last row of the scrolling list; beside the wide nav
/// it stays pinned under the rail (desktop-vs-mobile rule: width decides).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:slimm_app/src/features/settings/screens/personal_settings_screen.dart';
import 'package:slimm_app/src/features/settings/widgets/personal_account_sections.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'support/fake_api.dart';

Future<void> _pump(WidgetTester tester, Size size) async {
  PackageInfo.setMockInitialValues(
    appName: 'slim-m',
    packageName: 'top.npcserver.slimm',
    version: '0.1.0',
    buildNumber: '1',
    buildSignature: '',
  );
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      mockApiOverride((_) async => throw StateError('unexpected call')),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const PersonalSettingsScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('phone: Sign out is the end of the list, not a pinned footer', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 500));
    expect(find.text('Sign out'), findsNothing, reason: 'below the fold');

    await tester.dragUntilVisible(
      find.text('Sign out'),
      find.byType(ListView).first,
      const Offset(0, -200),
    );
    final list = tester.getRect(find.byType(ListView).first);
    expect(
      tester.getRect(find.text('Sign out')).bottom,
      lessThanOrEqualTo(list.bottom),
      reason: 'inside the scroll view, not beneath it',
    );
  });

  testWidgets('phone: Sign out icon lines up with the card rows above', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 1600));
    final signOutIcon = tester.getRect(find.byIcon(AppIcons.signOut));
    final rowIcon = tester.getRect(find.byIcon(AppIcons.account));
    expect(signOutIcon.left, rowIcon.left);
    final card = tester.getRect(find.byType(SettingsSectionCard).last);
    expect(
      card.left,
      tester.getRect(find.byType(SettingsSectionCard).first).left,
    );
  });

  testWidgets('phone: the search field sits close under the app bar', (
    tester,
  ) async {
    await _pump(tester, const Size(390, 844));
    final bar = tester.getRect(find.byType(AppBar));
    final search = tester.getRect(find.byKey(const Key('settings-search')));
    expect(search.top - bar.bottom, lessThanOrEqualTo(AppSpacing.s8));
    final firstGroup = tester.getRect(find.text('You'));
    expect(firstGroup.top - search.bottom, lessThanOrEqualTo(AppSpacing.s24));
  });

  testWidgets('wide: Sign out stays pinned under the nav rail', (tester) async {
    await _pump(tester, const Size(1280, 500));
    expect(find.text('Sign out'), findsOneWidget);
    final signOut = tester.getRect(find.text('Sign out'));
    expect(signOut.left, lessThan(240));
    final rail = tester.getRect(find.byType(ListView).first);
    final row = tester.getRect(find.byType(SignOutRow));
    expect(
      row.top,
      closeTo(rail.bottom, 2),
      reason: 'directly under the rail list, past its rule',
    );
    expect(
      row.bottom,
      closeTo(500, AppSpacing.s16),
      reason: 'pinned to the bottom of the rail, not floating mid-list',
    );
  });
}
