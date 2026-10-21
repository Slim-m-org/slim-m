// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clips whatever it wraps to the shared board, so nothing paints on the
/// letterbox. Decision 0073.
library;

import 'package:flutter/widgets.dart';

import 'canvas_document.dart';

/// [child] cut to the board's current place on screen; unclipped without a board.
class CanvasBoardClip extends StatelessWidget {
  const CanvasBoardClip(
      {super.key, required this.document, required this.child});

  final CanvasDocument document;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      ClipRect(clipper: _BoardClipper(document), child: child);
}

class _BoardClipper extends CustomClipper<Rect> {
  _BoardClipper(this.document) : super(reclip: document);

  final CanvasDocument document;

  @override
  Rect getClip(Size size) {
    final board = document.board;
    if (board == null) return Offset.zero & size;
    final camera = document.camera;
    return Rect.fromLTWH(
      (board.left - camera.x) * camera.zoom,
      (board.top - camera.y) * camera.zoom,
      board.width * camera.zoom,
      board.height * camera.zoom,
    );
  }

  @override
  bool shouldReclip(_BoardClipper oldClipper) =>
      oldClipper.document != document;
}
