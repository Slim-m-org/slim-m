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

  testWidgets('meta leads the detail line in the mono face', (tester) async {
    await _pump(
      tester,
      const SettingsDetailRow(title: 'Dice', meta: 'v1.2.0', detail: 'Rolls'),
    );
    final meta = tester.widget<Text>(find.text('v1.2.0'));
    expect(meta.style?.fontFamily, AppFonts.mono);
    expect(find.text('Rolls'), findsOneWidget);
  });

  testWidgets('onTap makes the whole row a labelled button', (tester) async {
    var taps = 0;
    await _pump(
      tester,
      SettingsDetailRow(
        title: 'Dice',
        onTap: () => taps++,
        onTapSemanticLabel: 'View Dice',
      ),
    );
    await tester.tap(find.bySemanticsLabel('View Dice'));
    expect(taps, 1);
  });

  testWidgets('an error sits under the row and can be dismissed', (
    tester,
  ) async {
    var dismissed = false;
    await _pump(
      tester,
      SettingsDetailRow(
        title: 'Dice',
        error: 'Could not revoke Dice.',
        onErrorDismiss: () => dismissed = true,
      ),
    );
    expect(find.text('Could not revoke Dice.'), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    expect(dismissed, isTrue);
  });

  testWidgets('trailing actions drop under the text on a narrow card only', (
    tester,
  ) async {
    Future<(Offset, Offset)> place(double width) async {
      await _pump(
        tester,
        Center(
          child: SizedBox(
            width: width,
            child: const SettingsDetailRow(
              icon: AppIcons.dock,
              title: 'helper',
              stackTrailingWhenNarrow: true,
              trailing: Text('actions'),
            ),
          ),
        ),
      );
      return (
        tester.getTopLeft(find.text('helper')),
        tester.getTopLeft(find.text('actions')),
      );
    }

    final (_, narrow) = await place(360);
    final (title, _) = await place(360);
    expect(narrow.dy, greaterThan(title.dy));
    final (wideTitle, wide) = await place(700);
    expect(wide.dy, lessThan(wideTitle.dy + 30));
    expect(wide.dx, greaterThan(wideTitle.dx));
  });
}
