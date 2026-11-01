// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The click-through window the sharer's own screen gets drawn on while
/// viewers annotate it; see docs/decisions/0096-screen-overlay.md.
///
/// The native runner owns the window and only paints what a frame says, in
/// coordinates normalised to the monitor it covers. Everything that decides
/// what a frame contains (fade, gating, mapping) stays in Dart.
library;

import 'dart:ui' show Color;

/// One monitor the overlay could cover, in the desktop's logical pixels.
class OverlayMonitor {
  const OverlayMonitor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primary,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;

  double get aspect => height == 0 ? 1 : width / height;

  static OverlayMonitor? fromReply(Object? reply) {
    if (reply is! Map) return null;
    final x = reply['x'], y = reply['y'];
    final w = reply['width'], h = reply['height'];
    if (x is! int || y is! int || w is! int || h is! int) return null;
    if (w <= 0 || h <= 0) return null;
    return OverlayMonitor(
      x: x,
      y: y,
      width: w,
      height: h,
      primary: reply['primary'] == true,
    );
  }
}

/// Whether this desktop can show the overlay, and over which monitors.
class OverlaySupport {
  const OverlaySupport({required this.supported, this.monitors = const []});

  const OverlaySupport.unsupported() : this(supported: false);

  final bool supported;
  final List<OverlayMonitor> monitors;

  static OverlaySupport fromReply(Object? reply) {
    if (reply is! Map || reply['supported'] != true) {
      return const OverlaySupport.unsupported();
    }
    final raw = reply['monitors'];
    final monitors = <OverlayMonitor>[];
    if (raw is List) {
      for (final m in raw) {
        final monitor = OverlayMonitor.fromReply(m);
        if (monitor != null) monitors.add(monitor);
      }
    }
    if (monitors.isEmpty) return const OverlaySupport.unsupported();
    return OverlaySupport(supported: true, monitors: monitors);
  }
}

/// A thing the overlay paints. Coordinates are 0 to 1 across the monitor;
/// [alpha] is already faded by the caller.
sealed class OverlayShape {
  const OverlayShape({required this.color, required this.alpha});

  final Color color;
  final double alpha;

  Map<String, Object?> toJson();
}

class OverlayStroke extends OverlayShape {
  const OverlayStroke({
    required this.points,
    required super.color,
    required super.alpha,
    this.width = 4,
  });

  /// Flat x, y pairs.
  final List<double> points;

  /// Logical pixels.
  final double width;

  @override
  Map<String, Object?> toJson() => {
        't': 'stroke',
        'points': points,
        'width': width,
        'color': color.toARGB32(),
        'alpha': alpha,
      };
}

class OverlayEllipse extends OverlayShape {
  const OverlayEllipse({
    required this.x0,
    required this.y0,
    required this.x1,
    required this.y1,
    required super.color,
    required super.alpha,
    this.width = 4,
  });

  final double x0, y0, x1, y1;
  final double width;

  @override
  Map<String, Object?> toJson() => {
        't': 'ellipse',
        'rect': [x0, y0, x1, y1],
        'width': width,
        'color': color.toARGB32(),
        'alpha': alpha,
      };
}

class OverlayNote extends OverlayShape {
  const OverlayNote({
    required this.x,
    required this.y,
    required this.text,
    required super.color,
    required super.alpha,
  });

  /// Top-left corner.
  final double x, y;
  final String text;

  @override
  Map<String, Object?> toJson() => {
        't': 'note',
        'x': x,
        'y': y,
        'text': text,
        'color': color.toARGB32(),
        'alpha': alpha,
      };
}

/// The overlay window, behind a seam so the app never touches the channel.
abstract class ScreenOverlay {
  Future<OverlaySupport> support();

  /// Covers [monitor] (an index into [OverlaySupport.monitors]); false when
  /// the window could not be made.
  Future<bool> show(int monitor);

  Future<void> draw(List<OverlayShape> shapes);

  Future<void> hide();
}
