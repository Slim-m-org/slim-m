// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a phone the picker opens in a bottom sheet that drags to dismiss. A drag
/// that starts on the square or the hue slider belongs to the picker, whichever
/// way it heads: the sheet must not take it and leave the thumb behind.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<List<Color>> _openPicker(WidgetTester tester) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final seen = <Color>[];
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => showAppColourPicker(
                context,
                initial: const Color(0xFFFF0000),
                onChanged: seen.add,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(seconds: 1));
  return seen;
}

Future<void> _drag(
  WidgetTester tester,
  Offset from,
  Offset step,
  int steps,
) async {
  final gesture = await tester.startGesture(from);
  for (var i = 0; i < steps; i++) {
    await gesture.moveBy(step);
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  testWidgets(
      'a vertical drag on the square follows the finger and the sheet '
      'stays put', (tester) async {
    final seen = await _openPicker(tester);
    final square = tester.getRect(
      find.bySemanticsLabel('Saturation and brightness'),
    );
    final titleBefore = tester.getTopLeft(find.text('Custom colour'));

    await _drag(
      tester,
      square.topLeft + const Offset(60, 8),
      const Offset(0, 8),
      10,
    );

    expect(
      HSVColor.fromColor(seen.last).value,
      closeTo(1 - 88 / square.height, 0.03),
    );
    expect(tester.getTopLeft(find.text('Custom colour')), titleBefore);
  });

  testWidgets(
      'a mostly vertical drag on the hue slider moves the hue and '
      'keeps the sheet', (tester) async {
    final seen = await _openPicker(tester);
    final slider = tester.getRect(find.bySemanticsLabel('Hue'));
    final titleBefore = tester.getTopLeft(find.text('Custom colour'));

    await _drag(
      tester,
      slider.centerLeft + const Offset(10, 0),
      const Offset(2, 6),
      6,
    );

    expect(
        HSVColor.fromColor(seen.last).hue, closeTo(22 / slider.width * 360, 6));
    expect(tester.getTopLeft(find.text('Custom colour')), titleBefore);
  });
}
