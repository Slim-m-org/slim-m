// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shared board: one fixed world-space frame every viewer fits to their
/// own screen, so the same content sits at the same relative place whatever
/// the window's size or aspect.
library;

import 'dart:math' as math;
import 'dart:ui';

import 'canvas_stroke.dart';

/// The board's frame in world units; 16:9 so it fills a laptop and a monitor
/// and letterboxes a portrait phone. Decision 0073.
const Rect canvasBoard = Rect.fromLTWH(0, 0, 1920, 1080);

/// The zoom at which [board] exactly fits [viewport], the lowest a viewer can go.
double boardFitZoom(Rect board, Size viewport) {
  if (viewport.isEmpty) return 1;
  return math.min(viewport.width / board.width, viewport.height / board.height);
}

/// The camera that shows the whole [board], centred and letterboxed.
Camera boardFitCamera(Rect board, Size viewport) => clampCameraToBoard(
      Camera(zoom: boardFitZoom(board, viewport)),
      board,
      viewport,
    );

/// [next] with its zoom held between the fit and [maxZoom] and its view kept
/// over the board: the board is centred on an axis it does not fill, and
/// pinned to its edges on one it overfills.
Camera clampCameraToBoard(Camera next, Rect board, Size viewport) {
  if (viewport.isEmpty) return next;
  final fit = boardFitZoom(board, viewport);
  final zoom = next.zoom.clamp(fit, math.max(fit, maxZoom)).toDouble();
  double axis(double start, double lo, double hi, double view) {
    final extent = view / zoom;
    if ((hi - lo) <= extent) return (lo + hi) / 2 - extent / 2;
    return start.clamp(lo, hi - extent).toDouble();
  }

  return Camera(
    x: axis(next.x, board.left, board.right, viewport.width),
    y: axis(next.y, board.top, board.bottom, viewport.height),
    zoom: zoom,
  );
}

/// The part of [board] a camera at [worldView] shows; what a follower is sent.
Rect visibleBoardPart(Rect worldView, Rect board) {
  final shown = worldView.intersect(board);
  return shown.isEmpty ? board : shown;
}

/// The camera that fits [view] inside [viewport] while keeping the viewport's
/// own aspect, so a follower on another shape sees extra board around it.
Camera cameraForBoardView(Rect view, Rect board, Size viewport) {
  if (viewport.isEmpty || view.isEmpty) return boardFitCamera(board, viewport);
  final zoom = math.min(
    viewport.width / view.width,
    viewport.height / view.height,
  );
  return clampCameraToBoard(
    Camera(
      x: view.center.dx - viewport.width / (2 * zoom),
      y: view.center.dy - viewport.height / (2 * zoom),
      zoom: zoom,
    ),
    board,
    viewport,
  );
}
