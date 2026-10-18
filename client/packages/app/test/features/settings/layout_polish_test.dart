// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Small wording and layout defects that only show at a narrow width or a
/// large text scale, each pinned by geometry rather than by a widget type.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/widgets/admin/channel_permissions_grid_rows.dart';
import 'package:slimm_app/src/features/settings/screens/admin/report_card_quick_actions.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_entity_row.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../ui_snapshot_support.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required Size size,
  double scale = 1,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearAllTestValues);
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the permissions legend names the blocked state like its peers', (
    tester,
  ) async {
    await _pump(tester, const Legend(), size: const Size(600, 200));
    expect(find.text("Inherit (you can't grant this)"), findsOneWidget);
    expect(find.text("you can't grant this"), findsNothing);
  });

  testWidgets('the empty pane heading is centred when it wraps', (
    tester,
  ) async {
    await _pump(
      tester,
      const NoChannelSelected(),
      size: const Size(240, 600),
      scale: 1.5,
    );
    final heading = tester.widget<Text>(
      find.text('Pick a channel to start reading.'),
    );
    expect(heading.textAlign, TextAlign.center);
  });

  testWidgets('the empty pane shortcut labels are not cut at 200 percent', (
    tester,
  ) async {
    await _pump(
      tester,
      const NoChannelSelected(),
      size: const Size(900, 800),
      scale: 2,
    );
    for (final label in ['Quick switcher', 'Next channel', 'Open settings']) {
      final box = tester.renderObject<RenderParagraph>(find.text(label));
      expect(box.didExceedMaxLines, isFalse, reason: label);
      expect(
        box.size.width,
        greaterThanOrEqualTo(box.getMaxIntrinsicWidth(double.infinity) - 0.5),
        reason: '$label should not be ellipsized',
      );
    }
  });

  testWidgets('the retention options each stay on one line on a phone', (
    tester,
  ) async {
    await _pump(
      tester,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 358,
              child: AppSegmentedControl.inline(
                options: const [
                  AppSegmentedOption(label: 'Never'),
                  AppSegmentedOption(label: '30 days'),
                  AppSegmentedOption(label: '90 days'),
                  AppSegmentedOption(label: '365 days'),
                ],
                selectedIndex: 0,
                onSegmentSelected: (_) {},
              ),
            ),
          ),
        ],
      ),
      size: const Size(390, 600),
    );
    final heights = {
      for (final l in ['Never', '30 days', '90 days', '365 days'])
        l: tester.getSize(find.text(l)).height,
    };
    expect(heights.values.toSet(), hasLength(1), reason: '$heights');
    expect(heights.values.first, lessThan(20), reason: '$heights');
  });

  testWidgets('the invite expiry options stay on one line at 200 percent', (
    tester,
  ) async {
    await _pump(
      tester,
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: SizedBox(
              width: 358,
              child: AppSegmentedControl.inline(
                options: const [
                  AppSegmentedOption(label: 'Never'),
                  AppSegmentedOption(label: '1 day'),
                  AppSegmentedOption(label: '7 days'),
                  AppSegmentedOption(label: '30 days'),
                ],
                selectedIndex: 0,
                onSegmentSelected: (_) {},
              ),
            ),
          ),
        ],
      ),
      size: const Size(390, 600),
      scale: 2,
    );
    final heights = {
      for (final l in ['Never', '1 day', '7 days', '30 days'])
        l: tester.getSize(find.text(l)).height,
    };
    expect(heights.values.toSet(), hasLength(1), reason: '$heights');
    expect(heights.values.first, lessThan(40), reason: '$heights');
  });

  testWidgets('the report card time out row lines up with the buttons above', (
    tester,
  ) async {
    await _pump(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: ReportQuickActions(
          busy: false,
          onDelete: () {},
          onTimeOut: (_) {},
        ),
      ),
      size: const Size(600, 600),
    );
    expect(
      tester.getTopLeft(find.byIcon(AppIcons.clock)).dx,
      moreOrLessEquals(tester.getTopLeft(find.byType(AppButton).first).dx + 0),
      reason: 'the clock should start where the first button starts',
    );
  });

  testWidgets('removed member actions stack under the name at 200 percent', (
    tester,
  ) async {
    await _pump(
      tester,
      SettingsEntityRow(
        headline: 'Grace Hopper',
        details: const [Text('Removed for spam')],
        actions: [
          AppButton(label: 'Let back in', onPressed: () {}),
          AppButton(label: 'Delete', onPressed: () {}),
        ],
      ),
      size: const Size(390, 800),
      scale: 2,
    );
    final name = tester.renderObject<RenderParagraph>(
      find.text('Grace Hopper'),
    );
    expect(name.didExceedMaxLines, isFalse);
    expect(
      tester.getTopLeft(find.text('Let back in')).dy,
      greaterThan(tester.getBottomLeft(find.text('Grace Hopper')).dy),
    );
  });
}
