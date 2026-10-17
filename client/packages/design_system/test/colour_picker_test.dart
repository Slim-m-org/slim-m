// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The colour picker: drag and keys move the value, hex entry parses, bad hex
/// shows an inline error and cannot be saved.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

Future<void> _pump(
  WidgetTester tester, {
  Color initial = const Color(0xFF3366CC),
  ValueChanged<Color>? onSave,
  VoidCallback? onCancel,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: AppColourPicker(
              initial: initial,
              onSave: onSave ?? (_) {},
              onCancel: onCancel ?? () {},
            ),
          ),
        ),
      ),
    ),
  );
}

String get _hexText =>
    (find.byType(EditableText).evaluate().single.widget as EditableText)
        .controller
        .text;

void main() {
  testWidgets('dragging the square changes the colour and the hex', (
    tester,
  ) async {
    await _pump(tester);
    final before = _hexText;
    final square = find.bySemanticsLabel('Saturation and brightness');
    final rect = tester.getRect(square);
    await tester.dragFrom(
        rect.topLeft + const Offset(4, 4), const Offset(60, 40));
    await tester.pump();
    expect(_hexText, isNot(before));
  });

  testWidgets('the top-left corner is white and the bottom is black', (
    tester,
  ) async {
    await _pump(tester);
    final rect =
        tester.getRect(find.bySemanticsLabel('Saturation and brightness'));
    await tester.tapAt(rect.topLeft);
    await tester.pump();
    expect(_hexText, '#FFFFFF');
    await tester.tapAt(rect.bottomLeft - const Offset(0, 0.01));
    await tester.pump();
    expect(_hexText, '#000000');
  });

  testWidgets('dragging the hue slider changes the hue', (tester) async {
    await _pump(tester, initial: const Color(0xFFFF0000));
    final rect = tester.getRect(find.bySemanticsLabel('Hue'));
    await tester.tapAt(Offset(rect.left + rect.width / 3, rect.center.dy));
    await tester.pump();
    expect(_hexText, '#00FF00');
  });

  testWidgets('arrow keys step the square and the hue slider', (tester) async {
    await _pump(tester, initial: const Color(0xFFFF0000));
    final before = _hexText;
    await tester.tap(find.bySemanticsLabel('Saturation and brightness'));
    await tester.pump();
    final afterTap = _hexText;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(_hexText, isNot(afterTap));
    expect(before, '#FF0000');
    final hueBefore = _hexText;
    await tester.tapAt(
      tester.getRect(find.bySemanticsLabel('Hue')).centerLeft +
          const Offset(1, 0),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(_hexText, isNot(hueBefore));
  });

  testWidgets('the surfaces report their value to a screen reader', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, initial: const Color(0xFFFF0000));
    expect(
      tester.getSemantics(find.bySemanticsLabel('Hue')).value,
      '0 degrees',
    );
    expect(
      tester
          .getSemantics(find.bySemanticsLabel('Saturation and brightness'))
          .value,
      '100% saturation, 100% brightness',
    );
    semantics.dispose();
  });

  testWidgets('typed hex with or without # moves the picker and saves', (
    tester,
  ) async {
    Color? saved;
    await _pump(tester, onSave: (c) => saved = c);
    await tester.enterText(find.byType(EditableText), '12ab34');
    await tester.pump();
    await tester.tap(find.text('Save'));
    expect(saved, const Color(0xFF12AB34));
    await tester.enterText(find.byType(EditableText), '#FFAA00');
    await tester.pump();
    await tester.tap(find.text('Save'));
    expect(saved, const Color(0xFFFFAA00));
  });

  testWidgets('bad hex shows an inline error and Save does nothing', (
    tester,
  ) async {
    Color? saved;
    await _pump(tester, onSave: (c) => saved = c);
    await tester.enterText(find.byType(EditableText), '#12G');
    await tester.pump();
    expect(find.text('Use a hex colour like #3A7BD5.'), findsOneWidget);
    await tester.tap(find.text('Save'), warnIfMissed: false);
    expect(saved, isNull);
    await tester.enterText(find.byType(EditableText), '#123456');
    await tester.pump();
    expect(find.text('Use a hex colour like #3A7BD5.'), findsNothing);
  });

  testWidgets('Cancel reports without saving', (tester) async {
    var cancelled = false;
    Color? saved;
    await _pump(tester,
        onSave: (c) => saved = c, onCancel: () => cancelled = true);
    await tester.tap(find.text('Cancel'));
    expect(cancelled, isTrue);
    expect(saved, isNull);
  });
}
