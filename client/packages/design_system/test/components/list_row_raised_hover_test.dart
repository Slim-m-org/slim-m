// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row in a sheet shows its hover and its press.
///
/// A row's hover fill was `surfaceRaised`, which is the colour a sheet paints
/// itself, so in the apps picker a hovered or pressed row looked exactly like
/// one at rest.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

const _tokens = AppTokens.dark;

/// Opens a sheet holding one row with [pointer], which stays where it tapped.
Future<void> _openSheet(
  WidgetTester tester,
  double width,
  TestGesture pointer,
) async {
  tester.view.physicalSize = Size(width, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, _tokens),
      home: Scaffold(
        body: Builder(
          builder: (context) => Align(
            alignment: Alignment.topLeft,
            child: TextButton(
              onPressed: () => showAppSheet<void>(
                context,
                builder: (_) => AppListRow(label: 'Minesweeper', onTap: () {}),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await pointer.moveTo(tester.getCenter(find.text('open')));
  await pointer.down(tester.getCenter(find.text('open')));
  await pointer.up();
  await tester.pumpAndSettle();
}

/// The fills the row paints, without the transparent layers.
List<Color> _rowFills(WidgetTester tester) => [
      for (final box in tester.widgetList<AnimatedContainer>(
        find.descendant(
          of: find.byType(AppListRow),
          matching: find.byType(AnimatedContainer),
        ),
      ))
        if ((box.decoration as BoxDecoration?)?.color case final color?
            when color.a > 0)
          color,
    ];

void main() {
  final desktop = TargetPlatformVariant.only(TargetPlatform.linux);

  testWidgets('a hovered row in a desktop sheet lifts off the sheet', (
    tester,
  ) async {
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await _openSheet(tester, 1200, mouse);

    await mouse.moveTo(tester.getCenter(find.text('Minesweeper')));
    await tester.pumpAndSettle();

    final fills = _rowFills(tester);
    expect(fills, isNotEmpty);
    expect(fills, everyElement(isNot(_tokens.surfaceRaised)));
    await mouse.removePointer();
  }, variant: desktop);

  testWidgets('a pressed row in a phone sheet shows the press', (
    tester,
  ) async {
    final finger = await tester.createGesture();
    await _openSheet(tester, 390, finger);

    await finger.down(tester.getCenter(find.text('Minesweeper')));
    await tester.pumpAndSettle();

    final fills = _rowFills(tester);
    expect(fills, isNotEmpty);
    expect(fills, everyElement(isNot(_tokens.surfaceRaised)));
    await finger.up();
  });

  testWidgets('a row on the page keeps its raised hover', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, _tokens),
        home: Scaffold(
          body: AppListRow(label: 'general', onTap: () {}),
        ),
      ),
    );
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    await mouse.moveTo(tester.getCenter(find.text('general')));
    await tester.pumpAndSettle();

    expect(_rowFills(tester), [_tokens.surfaceRaised]);
    await mouse.removePointer();
  }, variant: desktop);
}
