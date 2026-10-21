// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/widgets.dart';

/// Screen radius of the eraser ring: the 4 px hit slop plus a margin to see it.
const double eraserRingRadius = 10;

/// Replaces the system cursor with a ring while the eraser is armed, because no system cursor reads as an eraser.
class CanvasEraserRing extends StatefulWidget {
  const CanvasEraserRing({
    required this.active,
    required this.child,
    super.key,
  });

  final bool active;
  final Widget child;

  @override
  State<CanvasEraserRing> createState() => _CanvasEraserRingState();
}

class _CanvasEraserRingState extends State<CanvasEraserRing> {
  final ValueNotifier<Offset?> _at = ValueNotifier<Offset?>(null);

  @override
  void dispose() {
    _at.dispose();
    super.dispose();
  }

  void _track(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) return;
    _at.value = event.localPosition;
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      _at.value = null;
      return widget.child;
    }
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerHover: _track,
      onPointerMove: _track,
      onPointerDown: _track,
      child: MouseRegion(
        cursor: SystemMouseCursors.none,
        onExit: (_) => _at.value = null,
        child: CustomPaint(
          foregroundPainter: _RingPainter(_at),
          child: widget.child,
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.at) : super(repaint: at);

  final ValueNotifier<Offset?> at;

  @override
  void paint(Canvas canvas, Size size) {
    final center = at.value;
    if (center == null) return;
    Paint stroke(Color color, double width) => Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..color = color;
    canvas
      ..drawCircle(center, eraserRingRadius, stroke(const Color(0xCCFFFFFF), 3))
      ..drawCircle(
          center, eraserRingRadius, stroke(const Color(0xFF111111), 1.2));
  }

  @override
  bool shouldRepaint(_RingPainter old) => old.at != at;
}
