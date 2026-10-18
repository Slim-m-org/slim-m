// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// H P N S E through the full canvas pane, the tool strip's order and
/// geometry, and the default tool at a wide and a compact window.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'features/canvas/canvas_pane_harness.dart';

Finder _button(IconData icon) =>
    find.byWidgetPredicate((w) => w is AppIconButton && w.icon == icon);

CanvasTool? _activeTool(WidgetTester tester) {
  final icons = {
    CanvasTool.pan: AppIcons.pan,
    CanvasTool.pen: AppIcons.pen,
    CanvasTool.note: AppIcons.note,
    CanvasTool.eraser: AppIcons.eraser,
  };
  final active = <CanvasTool>[
    for (final entry in icons.entries)
      if (tester.widget<AppIconButton>(_button(entry.value)).active ?? false)
        entry.key,
    if (tester
            .widgetList<AppIconButton>(
              find.byWidgetPredicate(
                (w) => w is AppIconButton && w.semanticLabel == 'Shape',
              ),
            )
            .single
            .active ??
        false)
      CanvasTool.shape,
  ];
  return active.length == 1 ? active.single : null;
}

Future<void> _pump(
  WidgetTester tester,
  CanvasPaneFixture fixture,
  Size size,
) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = fixture.container();
  addTearDown(container.dispose);
  addTearDown(fixture.events.close);
  await pumpCanvasPane(tester, container);
  await tester.pumpAndSettle();
}

Future<void> _press(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyEvent(key);
  await tester.pump();
}

void main() {
  testWidgets('the strip draws pan, pen, note, shape, eraser left to right', (
    tester,
  ) async {
    await _pump(tester, CanvasPaneFixture(), const Size(1000, 700));

    final shape = find.byWidgetPredicate(
      (w) => w is AppIconButton && w.semanticLabel == 'Shape',
    );
    final xs = [
      tester.getCenter(_button(AppIcons.pan)).dx,
      tester.getCenter(_button(AppIcons.pen)).dx,
      tester.getCenter(_button(AppIcons.note)).dx,
      tester.getCenter(shape).dx,
      tester.getCenter(_button(AppIcons.eraser)).dx,
    ];
    expect([...xs]..sort(), xs, reason: 'left to right');
    final gaps = [for (var i = 1; i < xs.length; i++) xs[i] - xs[i - 1]];
    // The pen opens selected, so its caret widens only the pen-to-note gap.
    for (final i in [2, 3]) {
      expect(gaps[i], closeTo(gaps.first, 0.01), reason: 'even rhythm');
    }
    expect(gaps[1] - gaps.first, AppSizes.rowPointer, reason: 'the caret');
    expect(gaps.first, greaterThan(AppSpacing.s4));
  });

  testWidgets('the hand glyph is drawn and no tool wears the old move glyph', (
    tester,
  ) async {
    await _pump(tester, CanvasPaneFixture(), const Size(1000, 700));

    expect(_button(AppIcons.pan), findsOneWidget);
    expect(find.byIcon(AppIcons.pan), findsOneWidget);
    expect(find.bySemanticsLabel('Pan'), findsOneWidget);
    expect(find.bySemanticsLabel('Move'), findsNothing);
  });

  testWidgets('each key arms its tool, and the matching button shows it', (
    tester,
  ) async {
    await _pump(tester, CanvasPaneFixture(), const Size(1000, 700));

    final keyed = {
      LogicalKeyboardKey.keyH: CanvasTool.pan,
      LogicalKeyboardKey.keyN: CanvasTool.note,
      LogicalKeyboardKey.keyS: CanvasTool.shape,
      LogicalKeyboardKey.keyE: CanvasTool.eraser,
      LogicalKeyboardKey.keyP: CanvasTool.pen,
    };
    for (final entry in keyed.entries) {
      await _press(tester, entry.key);
      expect(_activeTool(tester), entry.value, reason: '${entry.key}');
    }
  });

  testWidgets('a modified letter does not arm a tool', (tester) async {
    await _pump(tester, CanvasPaneFixture(), const Size(1000, 700));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _press(tester, LogicalKeyboardKey.keyH);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

    expect(_activeTool(tester), CanvasTool.pen);
  });

  testWidgets('with the canvas unwritable P N S do nothing, H and E still do', (
    tester,
  ) async {
    await _pump(
      tester,
      CanvasPaneFixture(viewportStatus: 403),
      const Size(1000, 700),
    );
    expect(
      tester.widget<AppIconButton>(_button(AppIcons.pen)).onPressed,
      isNull,
    );

    await _press(tester, LogicalKeyboardKey.keyE);
    expect(_activeTool(tester), CanvasTool.eraser);
    for (final key in [
      LogicalKeyboardKey.keyP,
      LogicalKeyboardKey.keyN,
      LogicalKeyboardKey.keyS,
    ]) {
      await _press(tester, key);
      expect(_activeTool(tester), CanvasTool.eraser, reason: '$key');
    }
    await _press(tester, LogicalKeyboardKey.keyH);
    expect(_activeTool(tester), CanvasTool.pan);
  });

  testWidgets('a wide window opens on the pen', (tester) async {
    await _pump(tester, CanvasPaneFixture(), const Size(1000, 700));

    expect(_activeTool(tester), CanvasTool.pen);
  });

  testWidgets('a compact window opens on pan', (tester) async {
    await _pump(tester, CanvasPaneFixture(), const Size(400, 800));

    expect(_activeTool(tester), CanvasTool.pan);
  });
}
