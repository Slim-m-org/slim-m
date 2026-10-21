// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pan and zoom that land on a tile still move the camera.
///
/// A tile is opaque to the surface beneath it, so a trackpad two-finger
/// scroll or pinch and a two-finger touch pinch over a tile reached nothing,
/// and the scroll was read as a drag of the tile itself.
library;

import 'package:flutter/gestures.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

class TileCameraForwarder {
  TileCameraForwarder({required this.document, required this.originOf});

  final CanvasDocument document;

  /// Where the tile's top-left sits on screen, to turn a local point into a camera focal point.
  final Offset Function() originOf;

  final Map<int, Offset> _touches = {};
  double _lastTrackpadScale = 1;

  /// Two or more fingers are down on the tile, so a drag of it must not also move it.
  bool get pinching => _touches.length >= 2;

  void trackpadStart(PointerPanZoomStartEvent event) => _lastTrackpadScale = 1;

  void trackpadUpdate(PointerPanZoomUpdateEvent event) {
    final ratio = event.scale / _lastTrackpadScale;
    _lastTrackpadScale = event.scale;
    final camera = document.camera;
    final panned = camera.copyWith(
      x: camera.x - event.panDelta.dx / camera.zoom,
      y: camera.y - event.panDelta.dy / camera.zoom,
    );
    document.setCamera(
      ratio == 1
          ? panned
          : cameraAfterZoom(
              panned,
              focal: originOf() + event.localPosition,
              zoomTarget: panned.zoom * ratio,
            ),
    );
  }

  void touchDown(PointerDownEvent event) {
    if (event.kind != PointerDeviceKind.touch) return;
    _touches[event.pointer] = originOf() + event.localPosition;
  }

  void touchMove(PointerMoveEvent event) {
    if (!_touches.containsKey(event.pointer)) return;
    final before = _pair();
    _touches[event.pointer] = originOf() + event.localPosition;
    final after = _pair();
    if (before == null || after == null) return;
    _pinch(before, after);
  }

  void touchUp(PointerEvent event) => _touches.remove(event.pointer);

  void reset() => _touches.clear();

  ({Offset centre, double span})? _pair() {
    if (_touches.length < 2) return null;
    final points = _touches.values.take(2).toList();
    return (
      centre: (points[0] + points[1]) / 2,
      span: (points[0] - points[1]).distance,
    );
  }

  void _pinch(
    ({Offset centre, double span}) before,
    ({Offset centre, double span}) after,
  ) {
    final camera = document.camera;
    final shift = after.centre - before.centre;
    final panned = camera.copyWith(
      x: camera.x - shift.dx / camera.zoom,
      y: camera.y - shift.dy / camera.zoom,
    );
    final ratio = before.span == 0 ? 1.0 : after.span / before.span;
    document.setCamera(
      ratio == 1
          ? panned
          : cameraAfterZoom(
              panned,
              focal: after.centre,
              zoomTarget: panned.zoom * ratio,
            ),
    );
  }
}
