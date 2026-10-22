// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The selected pen and shape tools offer their options through the shared
/// controls-with-options pattern: a caret only while there is something to
/// pick, a long-press on touch, and targets that never shrink for it.
library;

import 'dart:ui' show Tristate;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_pen_style.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../support/canvas_call_dock_fixtures.dart';
import '../../support/canvas_tools_row_fixtures.dart';

Finder get _caret => find.byIcon(AppIcons.chevronDown);

Finder _tool(String label) => find.byWidgetPredicate(
  (w) => w is AppIconButton && w.semanticLabel == label,
);

List<String> _recordHaptics(WidgetTester tester) {
  final haptics = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add(call.arguments as String? ?? 'default');
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return haptics;
}

void main() {
  group('the caret', () {
    for (final (tool, expected) in [
      (CanvasTool.pen, true),
      (CanvasTool.shape, true),
      (CanvasTool.pan, false),
      (CanvasTool.note, false),
      (CanvasTool.eraser, false),
    ]) {
      testWidgets('${tool.name} selected: caret is $expected', (tester) async {
        await pumpCanvasCallDock(
          tester,
          canvas: buildCanvasDockData(tool: tool),
        );
        expect(_caret, expected ? findsOneWidget : findsNothing);
      });
    }

    testWidgets('an unselected pen has no caret and no long-press', (
      tester,
    ) async {
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(tool: CanvasTool.pan),
      );
      await tester.longPress(_tool('Pen'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Coral'), findsNothing);
    });

    testWidgets('a pen that cannot draw offers no options', (tester) async {
      await tester.pumpWidget(
        wrapCanvasToolsRow(buildCanvasToolsRow(canDraw: false)),
      );
      expect(_caret, findsNothing);
    });
  });

  group('picking reaches the dock data', () {
    testWidgets('a colour', (tester) async {
      CanvasPenStyle? pen;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(onPenChanged: (p) => pen = p),
      );
      await tester.tap(_caret);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Blue'));
      await tester.pumpAndSettle();
      expect(pen?.colorKey, 'blue');
      expect(pen?.width, canvasDefaultPenWidth);
      expect(find.byTooltip('Blue'), findsNothing, reason: 'picking closes it');
    });

    testWidgets('a width', (tester) async {
      CanvasPenStyle? pen;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(onPenChanged: (p) => pen = p),
      );
      await tester.tap(_caret);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Thick'));
      await tester.pumpAndSettle();
      expect(pen?.width, 6);
      expect(pen?.colorKey, canvasDefaultPenColorKey);
    });

    testWidgets('a shape kind, from the four kinds', (tester) async {
      CanvasShapeKind? kind;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(
          tool: CanvasTool.shape,
          onShapeKindChanged: (k) => kind = k,
        ),
      );
      await tester.tap(_caret);
      await tester.pumpAndSettle();
      expect(find.text('Rectangle'), findsOneWidget);
      expect(find.text('Ellipse'), findsOneWidget);
      expect(find.text('Arrow'), findsOneWidget);
      expect(find.text('Line'), findsOneWidget);
      await tester.tap(find.text('Arrow'));
      await tester.pumpAndSettle();
      expect(kind, CanvasShapeKind.arrow);
    });

    testWidgets('the pen offers six colours and three widths as swatches', (
      tester,
    ) async {
      await pumpCanvasCallDock(tester, canvas: buildCanvasDockData());
      await tester.tap(_caret);
      await tester.pumpAndSettle();
      for (final c in canvasPenColors) {
        expect(find.byTooltip(c.label), findsOneWidget);
        expect(find.text(c.label), findsNothing, reason: 'named, not drawn');
      }
      for (final w in canvasPenWidths) {
        expect(find.byTooltip(w.label), findsOneWidget);
      }
      expect(canvasPenColors, hasLength(6));
      expect(canvasPenWidths, hasLength(3));
      final ys = {
        for (final c in canvasPenColors)
          tester.getCenter(find.byTooltip(c.label)).dy,
      };
      expect(ys, hasLength(1), reason: 'the six colours share one line');
    });

    testWidgets('a plain press on the pen keeps its action and opens nothing', (
      tester,
    ) async {
      CanvasTool? chosen;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(
          tool: CanvasTool.pan,
          onToolChanged: (t) => chosen = t,
        ),
      );
      await tester.tap(_tool('Pen'));
      await tester.pumpAndSettle();
      expect(chosen, CanvasTool.pen);
      expect(find.byTooltip('Coral'), findsNothing);
    });

    testWidgets('a second press on the armed tool puts it down, back to Pan', (
      tester,
    ) async {
      CanvasTool? chosen;
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(onToolChanged: (t) => chosen = t),
      );
      await tester.tap(_tool('Pen'));
      await tester.pumpAndSettle();
      expect(chosen, CanvasTool.pan);
    });
  });

  testWidgets('a long-press on touch opens the options with a haptic', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final haptics = _recordHaptics(tester);
    await pumpCanvasCallDock(
      tester,
      canvas: buildCanvasDockData(),
      touch: true,
    );
    await tester.longPress(_tool('Pen'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Coral'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
    expect(haptics, contains('HapticFeedbackType.selectionClick'));
  });

  testWidgets('on a phone the options are a bottom sheet', (tester) async {
    tester.view.physicalSize = const Size(360, 780);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await pumpCanvasCallDock(
      tester,
      canvas: buildCanvasDockData(),
      width: 360,
      touch: true,
    );
    await tester.tap(_caret);
    await tester.pumpAndSettle();
    expect(find.byType(AppSheetMenu), findsOneWidget);
    expect(find.byTooltip('Medium'), findsOneWidget);
    final sheet = tester.getSize(find.byType(AppSheetMenu)).height;
    expect(sheet, lessThan(780 / 3), reason: 'about a quarter of the screen');
    for (final label in [
      ...canvasPenColors.map((c) => c.label),
      ...canvasPenWidths.map((w) => w.label),
    ]) {
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(AppSizes.rowTouch));
      expect(size.height, greaterThanOrEqualTo(AppSizes.rowTouch));
    }
  });

  testWidgets('on desktop every swatch keeps the 30dp pointer target', (
    tester,
  ) async {
    await pumpCanvasCallDock(tester, canvas: buildCanvasDockData());
    await tester.tap(_caret);
    await tester.pumpAndSettle();
    for (final label in [
      ...canvasPenColors.map((c) => c.label),
      ...canvasPenWidths.map((w) => w.label),
    ]) {
      final size = tester.getSize(find.byTooltip(label));
      expect(size.width, greaterThanOrEqualTo(AppSizes.rowPointer));
      expect(size.height, greaterThanOrEqualTo(AppSizes.rowPointer));
    }
  });

  group('keyboard and semantics', () {
    testWidgets('the caret is a tab stop, Enter opens it and Escape closes', (
      tester,
    ) async {
      await pumpCanvasCallDock(tester, canvas: buildCanvasDockData());
      for (var i = 0; i < 12; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        final focus = FocusManager.instance.primaryFocus?.context;
        if (focus != null &&
            find
                .descendant(of: _caretInk, matching: find.byType(Focus))
                .evaluate()
                .any((e) => e == focus)) {
          break;
        }
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Coral'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Coral'), findsNothing);
    });

    testWidgets('caret and choices carry labels, the current one is selected', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpCanvasCallDock(tester, canvas: buildCanvasDockData());
      expect(find.bySemanticsLabel('Pen options'), findsOneWidget);
      expect(find.bySemanticsLabel('Pen'), findsOneWidget);
      await tester.tap(_caret);
      await tester.pumpAndSettle();
      final current = tester.getSemantics(find.bySemanticsLabel('Coral'));
      expect(current.flagsCollection.isSelected == Tristate.isTrue, isTrue);
      final other = tester.getSemantics(find.bySemanticsLabel('Blue'));
      expect(other.flagsCollection.isSelected == Tristate.isTrue, isFalse);
      handle.dispose();
    });

    testWidgets('the shape tool has its own caret label', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(tool: CanvasTool.shape),
      );
      expect(find.bySemanticsLabel('Shape options'), findsOneWidget);
      handle.dispose();
    });
  });

  for (final touch in [true, false]) {
    final minimum = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    testWidgets('options never shrink a target below ${minimum}dp '
        '(touch: $touch)', (tester) async {
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(tool: CanvasTool.pan),
        touch: touch,
      );
      final penBefore = tester.getSize(_tool('Pen'));
      await pumpCanvasCallDock(
        tester,
        canvas: buildCanvasDockData(),
        touch: touch,
      );
      expect(tester.getSize(_tool('Pen')), penBefore);
      expect(penBefore.width, greaterThanOrEqualTo(minimum));
      expect(penBefore.height, greaterThanOrEqualTo(minimum));
      final hit = tester.getSize(_caretInk);
      expect(hit.width, greaterThanOrEqualTo(minimum));
      expect(hit.height, greaterThanOrEqualTo(minimum));
    });
  }

  testWidgets('the caret sits flush against the pen, with no gap', (
    tester,
  ) async {
    await pumpCanvasCallDock(tester, canvas: buildCanvasDockData());
    final pen = tester.getRect(
      find.descendant(of: _tool('Pen'), matching: find.byType(Container)).first,
    );
    final caret = tester.getRect(
      find.descendant(of: _caretInk, matching: find.byType(Container)).first,
    );
    expect(caret.left, closeTo(pen.right, 0.5));
    expect(caret.height, pen.height);
  });
}

Finder get _caretInk =>
    find.ancestor(of: _caret, matching: find.byType(InkWell));
