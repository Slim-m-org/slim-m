// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tool wheel: a held right button on empty canvas opens it, a flick picks
/// a tool, a quick right-click keeps the quick actions, and the keyboard and
/// screen readers reach the same tools.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_object_context_menu.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_wheel.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_tool_wheel_layer.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _hold = Duration(milliseconds: 600);

CanvasStrokeInput _note(String id) => CanvasStrokeInput(
  id: id,
  seq: 1,
  zIndex: 1,
  x: 100,
  y: 100,
  w: 80,
  h: 60,
  points: const [],
  width: 0,
  colorKey: 'shape',
  kind: CanvasObjectKind.note,
  text: 'note',
  authorId: 'me',
);

class _Rig {
  _Rig({bool withNote = false, this.canDraw = true}) {
    document = CanvasDocument()..setViewport(const Size(800, 600));
    if (withNote) document.applyPlaced(_note('a'));
  }

  late final CanvasDocument document;
  final bool canDraw;
  final wheel = CanvasToolWheelController();
  final tools = <CanvasTool>[];
  final pastes = <Offset>[];
  var tool = CanvasTool.pan;

  Widget build() => MaterialApp(
    theme: buildTheme(Brightness.dark, AppTokens.dark),
    home: Scaffold(
      body: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 800,
          height: 600,
          child: Stack(
            children: [
              CanvasObjectContextMenu(
                document: document,
                canManage: false,
                selfId: 'me',
                requests: CanvasObjectMenuRequests(),
                tool: tool,
                canDraw: canDraw,
                wheel: wheel,
                onBringToFront: (_) {},
                onSendToBack: (_) {},
                onDeleteSelected: (_) {},
                onPasteImageAt: (_) {},
                onAddNoteAt: (_) {},
                onRecenter: () {},
                onToolChanged: tools.add,
              ),
              CanvasToolWheelLayer(
                document: document,
                controller: wheel,
                tool: tool,
                shapeKind: CanvasShapeKind.rectangle,
                canDraw: canDraw,
                isObjectAt: (world) =>
                    world.dx >= 100 &&
                    world.dx <= 180 &&
                    world.dy >= 100 &&
                    world.dy <= 160 &&
                    document.objectBounds('a') != null,
                onToolChanged: tools.add,
                onPasteImageAt: pastes.add,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

Future<TestGesture> _rightDown(WidgetTester tester, Offset at) =>
    tester.startGesture(
      at,
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );

Finder get _wheel => find.byType(CanvasToolWheel);

Offset _itemAt(Offset anchor, CanvasWheelItem item) {
  final center = canvasWheelCenter(
    anchor,
    const Size(800, 600),
    EdgeInsets.zero,
  );
  return canvasWheelItemCenter(center, item.index);
}

void main() {
  group('geometry', () {
    test('a pointer inside the dead zone names no tool', () {
      expect(
        canvasWheelSector(center: Offset.zero, pointer: const Offset(10, 10)),
        isNull,
      );
    });

    test('each direction names the tool drawn there, wrapping at the top', () {
      for (final item in CanvasWheelItem.values) {
        final at = canvasWheelItemCenter(Offset.zero, item.index);
        expect(
          canvasWheelSector(center: Offset.zero, pointer: at * 0.6),
          item.index,
          reason: item.label,
        );
      }
      expect(
        canvasWheelSector(center: Offset.zero, pointer: const Offset(-8, -60)),
        0,
        reason: 'just left of straight up is still the top tool',
      );
    });

    test('the wheel is held inside the overlay with its whole ring', () {
      const bounds = Size(400, 300);
      final center = canvasWheelCenter(Offset.zero, bounds, EdgeInsets.zero);
      expect(center.dx, canvasWheelExtent);
      expect(center.dy, canvasWheelExtent);
      final far = canvasWheelCenter(
        const Offset(9999, 9999),
        bounds,
        EdgeInsets.zero,
      );
      expect(far.dx, bounds.width - canvasWheelExtent);
      expect(far.dy, bounds.height - canvasWheelExtent);
    });
  });

  group('a right button held on empty canvas', () {
    testWidgets('opens the wheel and, released in place, leaves it open', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      final gesture = await _rightDown(tester, const Offset(400, 300));
      await tester.pump(_hold);
      expect(_wheel, findsOneWidget);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_wheel, findsOneWidget, reason: 'a click can still pick');
      expect(find.byType(AppMenu), findsNothing, reason: 'no quick actions');
      expect(rig.tools, isEmpty);
    });

    testWidgets('a flick toward a tool and a release arms that tool', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final gesture = await _rightDown(tester, anchor);
      await tester.pump(_hold);
      await gesture.moveTo(_itemAt(anchor, CanvasWheelItem.pen));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rig.tools, [CanvasTool.pen]);
      expect(_wheel, findsNothing);
    });

    testWidgets('the wheel offers the text tool and a flick arms it', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final gesture = await _rightDown(tester, anchor);
      await tester.pump(_hold);
      await gesture.moveTo(_itemAt(anchor, CanvasWheelItem.text));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rig.tools, [CanvasTool.text]);
    });

    testWidgets('the Paste image item pastes at the held point', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final gesture = await _rightDown(tester, anchor);
      await tester.pump(_hold);
      await gesture.moveTo(_itemAt(anchor, CanvasWheelItem.pasteImage));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rig.pastes, [anchor]);
    });

    testWidgets('a tool that needs a writable canvas is not picked', (
      tester,
    ) async {
      final rig = _Rig(canDraw: false);
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final gesture = await _rightDown(tester, anchor);
      await tester.pump(_hold);
      await gesture.moveTo(_itemAt(anchor, CanvasWheelItem.pen));
      await gesture.up();
      await tester.pumpAndSettle();

      expect(rig.tools, isEmpty);
    });

    testWidgets('over an object it opens no wheel, the object menu stays', (
      tester,
    ) async {
      final rig = _Rig(withNote: true);
      await tester.pumpWidget(rig.build());
      final gesture = await _rightDown(tester, const Offset(120, 120));
      await tester.pump(_hold);
      expect(_wheel, findsNothing);
      await gesture.up();
      await tester.pumpAndSettle();

      expect(_wheel, findsNothing);
      expect(find.text('Bring to front'), findsOneWidget);
    });
  });

  group('a compact, quick, self-dismissing wheel', () {
    testWidgets('opens within a short hold, not the long-press timeout', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      await _rightDown(tester, const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 200));
      expect(_wheel, findsOneWidget);
    });

    testWidgets('is no wider than 150 logical pixels', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      await _rightDown(tester, const Offset(400, 300));
      await tester.pump(const Duration(milliseconds: 200));
      final disc = find.descendant(
        of: _wheel,
        matching: find.byType(DecoratedBox),
      );
      final size = tester.getSize(disc.first);
      expect(size.width, lessThanOrEqualTo(150));
      expect(size.width, size.height);
    });

    testWidgets('every item keeps a pointer-sized target', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      rig.wheel.requestOpen();
      await tester.pumpAndSettle();
      for (final item in CanvasWheelItem.values) {
        final size = tester.getSize(find.bySemanticsLabel(item.label));
        expect(size.shortestSide, greaterThanOrEqualTo(AppSizes.rowPointer));
      }
    });

    testWidgets('hovering past the wheel edge dismisses it, inside does not', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final held = await _rightDown(tester, anchor);
      await tester.pump(const Duration(milliseconds: 200));
      await held.up();
      await tester.pump();
      final mouse = held;
      await mouse.moveTo(anchor + const Offset(6, 0));
      await tester.pump();
      await mouse.moveTo(anchor + const Offset(canvasWheelExtent - 4, 0));
      await tester.pump();
      expect(_wheel, findsOneWidget);

      await mouse.moveTo(anchor + const Offset(canvasWheelExtent + 20, 0));
      await tester.pump();
      expect(_wheel, findsNothing);
      expect(rig.tools, isEmpty);
    });

    testWidgets('the square corner of the wheel box is outside the circle', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final held = await _rightDown(tester, anchor);
      await tester.pump(const Duration(milliseconds: 200));
      await held.up();
      await tester.pump();
      final mouse = held;
      await mouse.moveTo(anchor + const Offset(6, 0));
      await tester.pump();
      const corner = canvasWheelExtent - 2;
      await mouse.moveTo(anchor + const Offset(corner, corner));
      await tester.pump();
      expect(_wheel, findsNothing);
    });

    testWidgets('clicking an item arms the tool and closes the wheel', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      const anchor = Offset(400, 300);
      final held = await _rightDown(tester, anchor);
      await tester.pump(const Duration(milliseconds: 200));
      await held.up();
      await tester.pump();
      await tester.tapAt(_itemAt(anchor, CanvasWheelItem.shape));
      await tester.pump();

      expect(rig.tools, [CanvasTool.shape]);
      expect(_wheel, findsNothing);
    });
  });

  group('a quick right-click', () {
    testWidgets('keeps the quick actions and opens no wheel', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
      await tester.pumpAndSettle();

      expect(_wheel, findsNothing);
      expect(find.text('Recenter view'), findsOneWidget);
    });

    testWidgets('right after a hold still opens the quick actions', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      final held = await _rightDown(tester, const Offset(400, 300));
      await tester.pump(_hold);
      await held.up();
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(60, 60));
      await tester.pumpAndSettle();
      expect(_wheel, findsNothing);

      await tester.tapAt(const Offset(400, 300), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.text('Recenter view'), findsOneWidget);
    });
  });

  group('without a pointer', () {
    testWidgets('the controller opens the wheel, arrows move, Enter picks', (
      tester,
    ) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      rig.wheel.requestOpen();
      await tester.pumpAndSettle();
      expect(_wheel, findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(rig.tools, hasLength(1));
      expect(_wheel, findsNothing);
    });

    testWidgets('Escape closes it without choosing', (tester) async {
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      rig.wheel.requestOpen();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(_wheel, findsNothing);
      expect(rig.tools, isEmpty);
    });

    testWidgets('screen readers get the wheel and every tool by name', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final rig = _Rig();
      await tester.pumpWidget(rig.build());
      rig.wheel.requestOpen();
      await tester.pumpAndSettle();

      expect(find.bySemanticsLabel('Tool wheel'), findsOneWidget);
      for (final item in CanvasWheelItem.values) {
        expect(find.bySemanticsLabel(item.label), findsOneWidget);
      }
      handle.dispose();
    });
  });
}
