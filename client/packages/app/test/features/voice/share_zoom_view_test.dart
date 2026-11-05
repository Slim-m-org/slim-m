// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Zoom and pan input over a watched share: wheel, trackpad, pinch, keys and drag, the indicator, and the stage's double click.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/share_zoom_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/screen_share_stage.dart';
import 'package:slimm_app/src/features/voice/widgets/share_zoom_view.dart';
import 'package:slimm_design_system/design_system.dart';

const _viewKey = Key('zoom-view');
const _level = Key('share-zoom-level');
const _reset = Key('share-zoom-reset');

Future<ShareZoomController> _pump(
  WidgetTester tester, {
  bool wheelNeedsCtrl = false,
  bool pinch = true,
}) async {
  final zoom = ShareZoomController();
  addTearDown(zoom.dispose);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildTheme(Brightness.dark, AppTokens.dark),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            key: _viewKey,
            width: 400,
            height: 300,
            child: ShareZoomView(
              zoom: zoom,
              wheelNeedsCtrl: wheelNeedsCtrl,
              pinch: pinch,
              child: const ColoredBox(color: Color(0xFF20252B)),
            ),
          ),
        ),
      ),
    ),
  );
  return zoom;
}

Future<void> _wheel(WidgetTester tester, double dy, {Offset? at}) async {
  final pointer = TestPointer(1, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(
    pointer.hover(at ?? tester.getCenter(find.byKey(_viewKey))),
  );
  await tester.sendEventToBinding(pointer.scroll(Offset(0, dy)));
  await tester.pump();
}

void main() {
  testWidgets('the wheel zooms in and shows the level with a reset', (
    tester,
  ) async {
    final zoom = await _pump(tester);
    expect(find.byKey(_level), findsNothing);
    await _wheel(tester, -100);
    expect(zoom.zoomed, isTrue);
    expect(find.byKey(_level), findsOneWidget);
    expect(find.text('${zoom.percent}%'), findsOneWidget);
    await tester.tap(find.byKey(_reset));
    await tester.pump();
    expect(zoom.zoomed, isFalse);
    expect(find.byKey(_level), findsNothing);
  });

  testWidgets('the wheel zooms about the cursor', (tester) async {
    final zoom = await _pump(tester);
    final box = tester.getRect(find.byKey(_viewKey));
    await _wheel(tester, -100, at: box.topLeft + const Offset(300, 75));
    final p = const Offset(0.75, 0.25) * zoom.scale + zoom.origin;
    expect(p.dx, closeTo(0.75, 1e-6));
    expect(p.dy, closeTo(0.25, 1e-6));
  });

  testWidgets('scrolling out at fit is left alone', (tester) async {
    final zoom = await _pump(tester);
    await _wheel(tester, 100);
    expect(zoom.zoomed, isFalse);
  });

  test('scrolling out at fit is not claimed, so a parent can scroll', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    final zoom = ShareZoomController();
    const out = PointerScrollEvent(
      position: Offset(10, 10),
      scrollDelta: Offset(0, 100),
    );
    const size = Size(400, 300);
    expect(applyShareZoomSignal(zoom, out, size), isFalse);
    zoom.zoomAt(2, Offset.zero);
    expect(applyShareZoomSignal(zoom, out, size), isTrue);
  });

  testWidgets('where the wheel belongs to something else it takes ctrl', (
    tester,
  ) async {
    final zoom = await _pump(tester, wheelNeedsCtrl: true);
    await _wheel(tester, -100);
    expect(zoom.zoomed, isFalse);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await _wheel(tester, -100);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(zoom.zoomed, isTrue);
  });

  testWidgets('a trackpad pinch zooms', (tester) async {
    final zoom = await _pump(tester);
    final pointer = TestPointer(1, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(
      pointer.hover(tester.getCenter(find.byKey(_viewKey))),
    );
    await tester.sendEventToBinding(
      PointerScaleEvent(
        position: tester.getCenter(find.byKey(_viewKey)),
        scale: 1.5,
      ),
    );
    expect(zoom.scale, closeTo(1.5, 1e-9));
  });

  testWidgets('dragging pans a zoomed view and does nothing at fit', (
    tester,
  ) async {
    final zoom = await _pump(tester);
    final centre = tester.getCenter(find.byKey(_viewKey));
    await tester.dragFrom(centre, const Offset(80, 0));
    expect(zoom.origin, Offset.zero);

    zoom.zoomAt(2, const Offset(0.5, 0.5));
    await tester.pump();
    await tester.dragFrom(centre, const Offset(80, 0));
    expect(zoom.origin.dx, closeTo(-0.5 + 80 / 400, 0.05));
    expect(zoom.origin.dy, closeTo(-0.5, 1e-9));
  });

  testWidgets('two fingers pinch it', (tester) async {
    final zoom = await _pump(tester);
    final c = tester.getCenter(find.byKey(_viewKey));
    final a = await tester.startGesture(c - const Offset(20, 0), pointer: 1);
    final b = await tester.startGesture(c + const Offset(20, 0), pointer: 2);
    await a.moveTo(c - const Offset(60, 0));
    await b.moveTo(c + const Offset(60, 0));
    await tester.pump();
    expect(zoom.scale, greaterThan(2));
    await a.up();
    await b.up();
  });

  testWidgets('where two fingers belong to something else they do nothing', (
    tester,
  ) async {
    final zoom = await _pump(tester, pinch: false);
    final c = tester.getCenter(find.byKey(_viewKey));
    final a = await tester.startGesture(c - const Offset(20, 0), pointer: 1);
    final b = await tester.startGesture(c + const Offset(20, 0), pointer: 2);
    await a.moveTo(c - const Offset(60, 0));
    await b.moveTo(c + const Offset(60, 0));
    await tester.pump();
    expect(zoom.zoomed, isFalse);
    await a.up();
    await b.up();
  });

  testWidgets('plus, minus and zero work once the view has focus', (
    tester,
  ) async {
    final zoom = await _pump(tester);
    await tester.tapAt(tester.getCenter(find.byKey(_viewKey)));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    expect(zoom.scale, closeTo(shareZoomKeyStep, 1e-9));
    await tester.sendKeyEvent(LogicalKeyboardKey.minus);
    expect(zoom.zoomed, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.equal);
    await tester.sendKeyEvent(LogicalKeyboardKey.digit0);
    expect(zoom.zoomed, isFalse);
  });

  testWidgets('the picture is scaled by the zoom', (tester) async {
    final zoom = await _pump(tester);
    zoom.zoomAt(2, Offset.zero);
    await tester.pump();
    final transform = tester.widget<Transform>(
      find.byKey(const ValueKey('share-zoom-transform')),
    );
    expect(transform.transform.getMaxScaleOnAxis(), closeTo(2, 1e-9));
  });

  testWidgets('on the stage a double click resets a zoom before it expands', (
    tester,
  ) async {
    var expanded = 0;
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                key: _viewKey,
                width: 800,
                height: 450,
                child: ScreenShareStage(
                  sharerName: 'Ada',
                  onExpand: () => expanded++,
                  child: const ColoredBox(color: Color(0xFF20252B)),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final c = tester.getCenter(find.byKey(_viewKey));
    await _wheel(tester, -100, at: c);
    expect(find.byKey(_level), findsOneWidget);

    Future<void> doubleClick() async {
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(c);
      await tester.pump(const Duration(milliseconds: 50));
    }

    await doubleClick();
    expect(find.byKey(_level), findsNothing);
    expect(expanded, 0);
    await doubleClick();
    expect(expanded, 1);
  });
}
