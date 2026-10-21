// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A wheel notch's effect on the camera, as pure functions rather than a
/// method on [CanvasSurface]'s own gesture state.
///
/// [CanvasSurface]'s own pointer-signal handler is not the only thing a
/// wheel event can land on: anything painted in front of it with an opaque
/// hit test - a manipulable presence tile, in the app layer - has to answer
/// for a wheel event landing on itself too, or scrolling there silently does
/// nothing while the same gesture over bare canvas works. A second,
/// independent copy of this arithmetic in that caller would drift the day
/// only one of them was changed, so both read the same function instead.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'canvas_stroke.dart';

/// A plain wheel notch pans; ctrl/cmd zooms about [focal]; shift adds the
/// horizontal axis a single-axis wheel cannot report on its own - see
/// [CanvasSurface]'s own former doc, now here, for why an unmodified
/// trackpad swipe already reports both axes and must keep panning freely
/// rather than being folded into this same branch.
Camera cameraAfterWheelScroll(
  Camera camera, {
  required Offset focal,
  required double dx,
  required double dy,
  required bool zoomModifier,
  required bool horizontalModifier,
  double zoomFloor = minZoom,
}) {
  if (zoomModifier) {
    if (dy == 0) return camera;
    return cameraAfterZoom(
      camera,
      focal: focal,
      zoomTarget: camera.zoom * wheelZoomFactor(dy),
      zoomFloor: zoomFloor,
    );
  }
  if (horizontalModifier) {
    final horizontal = dx != 0 ? dx : dy;
    return camera.copyWith(x: camera.x + horizontal / camera.zoom);
  }
  return camera.copyWith(
    x: camera.x + dx / camera.zoom,
    y: camera.y + dy / camera.zoom,
  );
}

/// How much one wheel event of vertical delta [dy] scales the zoom.
///
/// Proportional to the delta so a smooth wheel's many small events add up to
/// what one notch does, and capped so a single large delta cannot leap.
double wheelZoomFactor(double dy) => math
    .exp(-dy * _zoomPerWheelPixel)
    .clamp(minWheelZoomStep, maxWheelZoomStep);

const double _zoomPerWheelPixel = 0.0015;
const double minWheelZoomStep = 0.8;
const double maxWheelZoomStep = 1.25;

/// Solves directly for the camera that leaves the world point under [focal]
/// exactly where it was, at the new zoom - one result rather than a
/// set-then-correct pair, so a camera already near a world edge cannot have
/// an intermediate clamp shift x/y before the correction ever reads it.
/// [zoomTarget] is clamped here, since the offset below needs the zoom that
/// will actually land; the no-op return spares a wheel notch already parked
/// at a bound the cost of a camera change nothing will show for.
Camera cameraAfterZoom(
  Camera camera, {
  required Offset focal,
  required double zoomTarget,
  double zoomFloor = minZoom,
}) {
  // A board fit can sit below minZoom; never turn a zoom-out into a zoom-in.
  final zoom =
      zoomTarget.clamp(math.min(zoomFloor, camera.zoom), maxZoom).toDouble();
  if (zoom == camera.zoom) return camera;
  final worldFocal = Offset(
    camera.x + focal.dx / camera.zoom,
    camera.y + focal.dy / camera.zoom,
  );
  return camera.copyWith(
    x: worldFocal.dx - focal.dx / zoom,
    y: worldFocal.dy - focal.dy / zoom,
    zoom: zoom,
  );
}
