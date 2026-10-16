// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/settings_detail_row.dart';
import 'package:slimm_app/src/widgets/settings_empty.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(WidgetTester tester, Widget child) => tester.pumpWidget(
  MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(body: child),
  ),
);

void main() {
  testWidgets('a detail row shows title, badge, detail and trailing', (
    tester,
  ) async {
    await _pump(
      tester,
      const SettingsDetailRow(
        icon: AppIcons.deviceLaptop,
        title: 'Linux',
        badge: AppBadge(variant: AppBadgeVariant.tag, label: 'This device'),
        detail: 'Desktop 1.0 · active now',
        trailing: Text('trailing'),
      ),
    );
    expect(find.text('Linux'), findsOneWidget);
    expect(find.text('THIS DEVICE'), findsOneWidget);
    expect(find.text('Desktop 1.0 · active now'), findsOneWidget);
    expect(find.text('trailing'), findsOneWidget);
    expect(tester.getSize(find.byType(SettingsIconTile)), const Size(32, 32));
  });

  testWidgets('a dimmed row is drawn at reduced opacity', (tester) async {
    await _pump(tester, const SettingsDetailRow(title: 'Old', dimmed: true));
    expect(tester.widget<Opacity>(find.byType(Opacity)).opacity, 0.6);
  });

  testWidgets('the group label is uppercased', (tester) async {
    await _pump(tester, const SettingsGroupLabelRow('Not used recently'));
    expect(find.text('NOT USED RECENTLY'), findsOneWidget);
  });

  testWidgets('the empty state carries title and detail', (tester) async {
    await _pump(
      tester,
      const SettingsEmptyState(
        icon: AppIcons.revoke,
        title: 'Nobody is blocked',
        detail: 'People you block will be listed here.',
      ),
    );
    expect(find.text('Nobody is blocked'), findsOneWidget);
    expect(find.text('People you block will be listed here.'), findsOneWidget);
  });
}
