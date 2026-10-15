// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The density seam: what a control does when its caller says nothing.
///
/// The `touch` flag existed, was documented, was tested, and every call site
/// in the client forgot it. These assert the resolution order that replaced
/// remembering: an enclosing scope, then the window width, then pointer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1400, 900);

Future<void> _pump(WidgetTester tester, Size size, Widget child) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  return tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    ),
  );
}

void main() {
  group('unset touch follows the width', () {
    testWidgets('a compact window puts every control at the touch floor',
        (tester) async {
      await _pump(
        tester,
        _phone,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIconButton(icon: AppIcons.add, semanticLabel: 'Add'),
            SizedBox(width: 240, child: AppListRow(label: 'general')),
            AppButton(label: 'Save'),
            SizedBox(width: 240, child: AppMenuItem(label: 'Copy text')),
          ],
        ),
      );

      expect(tester.getSize(find.byType(AppIconButton)).shortestSide,
          AppSizes.rowTouch);
      expect(tester.getSize(find.byType(AppListRow)).height, AppSizes.rowTouch);
      expect(tester.getSize(find.byType(AppButton)).height, AppSizes.rowTouch);
      expect(
        tester.getSize(find.byType(AppMenuItem)).height,
        AppSizes.rowTouchMenu,
      );
    });

    testWidgets('a desktop window leaves every control at pointer size',
        (tester) async {
      await _pump(
        tester,
        _desktop,
        const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AppIconButton(icon: AppIcons.add, semanticLabel: 'Add'),
            SizedBox(width: 240, child: AppListRow(label: 'general')),
            AppButton(label: 'Save'),
            SizedBox(width: 240, child: AppMenuItem(label: 'Copy text')),
          ],
        ),
      );

      expect(tester.getSize(find.byType(AppIconButton)).shortestSide,
          AppSizes.rowPointer);
      expect(
          tester.getSize(find.byType(AppListRow)).height, AppSizes.rowPointer);
      // Its own md metric, which already clears the pointer floor.
      expect(tester.getSize(find.byType(AppButton)).height, AppSizes.controlMd);
      expect(
          tester.getSize(find.byType(AppMenuItem)).height, AppSizes.controlMd);
    });
  });

  testWidgets('an explicit flag still wins over the width', (tester) async {
    await _pump(
      tester,
      _phone,
      const SizedBox(
          width: 240, child: AppListRow(label: 'general', touch: false)),
    );

    expect(tester.getSize(find.byType(AppListRow)).height, AppSizes.rowPointer);
  });

  testWidgets('a scope wins over the width', (tester) async {
    await _pump(
      tester,
      _desktop,
      const AppTouchTargets(
        enabled: true,
        child: SizedBox(width: 240, child: AppListRow(label: 'general')),
      ),
    );

    expect(tester.getSize(find.byType(AppListRow)).height, AppSizes.rowTouch);
  });

  testWidgets('a taller row keeps its height at touch density', (tester) async {
    await _pump(
      tester,
      _phone,
      const SizedBox(width: 240, child: AppListRow(label: 'Priya', height: 52)),
    );

    expect(tester.getSize(find.byType(AppListRow)).height, 52);
  });

  group('AppChip.reaction keeps its hit floor regardless of visual padding',
      () {
    // Tighter chip padding must not shrink the tappable margin around it.
    Widget chip() => AppChip.reaction(
        emoji: '\u{1F44D}', count: 3, active: false, onTap: () {});

    testWidgets('a compact window puts the reaction chip at the touch floor',
        (tester) async {
      await _pump(tester, _phone, chip());

      expect(tester.getSize(find.byType(GestureDetector).first).height,
          AppSizes.rowTouch);
    });

    testWidgets(
        'a desktop window never shrinks the reaction chip below pointer size',
        (tester) async {
      await _pump(tester, _desktop, chip());

      // Never smaller than the floor, not an exact incidental measurement.
      expect(tester.getSize(find.byType(GestureDetector).first).height,
          greaterThanOrEqualTo(AppSizes.rowPointer));
    });
  });
}
