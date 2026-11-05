// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Zoom and pan of a watched share: the point under the cursor stays put, the picture never leaves the viewport, and the keys step it.
library;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show KeyEventResult;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/share_zoom_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('starts at fit', () {
    final zoom = ShareZoomController();
    expect((zoom.scale, zoom.zoomed, zoom.percent), (1.0, false, 100));
  });

  test('zooming about a point keeps that point where it was', () {
    final zoom = ShareZoomController()..zoomAt(2, const Offset(0.75, 0.25));
    final p = const Offset(0.75, 0.25) * zoom.scale + zoom.origin;
    expect(p.dx, closeTo(0.75, 1e-9));
    expect(p.dy, closeTo(0.25, 1e-9));
  });

  test('scale stops at the maximum and never goes below fit', () {
    final zoom = ShareZoomController()..zoomAt(100, const Offset(0.5, 0.5));
    expect(zoom.scale, shareZoomMax);
    zoom.zoomAt(0.001, const Offset(0.5, 0.5));
    expect((zoom.scale, zoom.origin), (1.0, Offset.zero));
  });

  test('the picture cannot be dragged off the viewport', () {
    final zoom = ShareZoomController()..zoomAt(2, const Offset(0.5, 0.5));
    zoom.panBy(const Offset(5, 5));
    expect(zoom.origin, Offset.zero);
    zoom.panBy(const Offset(-5, -5));
    expect(zoom.origin, const Offset(-1, -1));
  });

  test('a pan at fit does nothing', () {
    final zoom = ShareZoomController()..panBy(const Offset(0.3, 0.3));
    expect(zoom.origin, Offset.zero);
  });

  test('toggle jumps to the toggle scale and back to fit', () {
    final zoom = ShareZoomController()..toggle();
    expect(zoom.scale, shareZoomToggleScale);
    zoom.toggle();
    expect((zoom.scale, zoom.origin), (1.0, Offset.zero));
  });

  test('apply maps a fitted rect into the zoomed viewport', () {
    final zoom = ShareZoomController()..zoomAt(2, Offset.zero);
    final rect = zoom.apply(
      const Rect.fromLTWH(10, 20, 100, 50),
      const Size(400, 300),
    );
    expect(rect, const Rect.fromLTWH(20, 40, 200, 100));
  });

  test('plus, minus and zero step and reset around the centre', () {
    final zoom = ShareZoomController();
    KeyEventResult press(LogicalKeyboardKey key) => zoom.handleKey(
      KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyA,
        logicalKey: key,
        timeStamp: Duration.zero,
      ),
    );
    expect(press(LogicalKeyboardKey.equal), KeyEventResult.handled);
    expect(zoom.scale, closeTo(shareZoomKeyStep, 1e-9));
    press(LogicalKeyboardKey.numpadAdd);
    expect(zoom.scale, closeTo(shareZoomKeyStep * shareZoomKeyStep, 1e-9));
    press(LogicalKeyboardKey.minus);
    expect(zoom.scale, closeTo(shareZoomKeyStep, 1e-9));
    press(LogicalKeyboardKey.digit0);
    expect(zoom.zoomed, isFalse);
    expect(press(LogicalKeyboardKey.keyQ), KeyEventResult.ignored);
  });

  test('a set forgets the zoom of a tile that went away', () {
    final set = ShareZoomSet();
    final first = set.of('screen:a')..zoomAt(2, Offset.zero);
    expect(set.of('screen:a'), same(first));
    set.keepOnly({'screen:b'});
    expect(set.of('screen:a').zoomed, isFalse);
  });
}
