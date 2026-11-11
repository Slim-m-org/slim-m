// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The click-through window the sharer's own screen gets drawn on while
/// viewers annotate it; see docs/decisions/0096-screen-overlay.md.
///
/// The native runner owns the window and only paints what a frame says, in
/// coordinates normalised to the monitor it covers. Everything that decides
/// what a frame contains (fade, gating, mapping) stays in Dart.
library;

import 'dart:typed_data' show Uint8List;
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart' show listEquals;

/// One monitor the overlay could cover, in the desktop's logical pixels.
class OverlayMonitor {
  const OverlayMonitor({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.primary,
    this.deviceIndex,
    this.capturePosition,
  });

  final int x;
  final int y;
  final int width;
  final int height;
  final bool primary;

  /// Windows: the display device index libwebrtc uses as this screen's source id.
  final int? deviceIndex;

  /// Windows: this screen's 0-based place in libwebrtc's "Screen N" order.
  final int? capturePosition;

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
      deviceIndex: _nonNegative(reply['deviceIndex']),
      capturePosition: _nonNegative(reply['capturePosition']),
    );
  }
}

int? _nonNegative(Object? value) => value is int && value >= 0 ? value : null;

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
/// [alpha] is already faded by the caller. Value equality is what lets the
/// caller skip a frame that says what the last one did.
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

  @override
  bool operator ==(Object other) =>
      other is OverlayStroke &&
      other.color == color &&
      other.alpha == alpha &&
      other.width == width &&
      listEquals(other.points, points);

  @override
  int get hashCode => Object.hash(color, alpha, width, Object.hashAll(points));
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

  @override
  bool operator ==(Object other) =>
      other is OverlayEllipse &&
      other.color == color &&
      other.alpha == alpha &&
      other.width == width &&
      other.x0 == x0 &&
      other.y0 == y0 &&
      other.x1 == x1 &&
      other.y1 == y1;

  @override
  int get hashCode => Object.hash(color, alpha, width, x0, y0, x1, y1);
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

  @override
  bool operator ==(Object other) =>
      other is OverlayNote &&
      other.color == color &&
      other.alpha == alpha &&
      other.x == x &&
      other.y == y &&
      other.text == text;

  @override
  int get hashCode => Object.hash(color, alpha, x, y, text);
}

/// Which corner of the monitor the call panel sits in.
enum OverlayCorner {
  topLeft('Top left'),
  topRight('Top right'),
  bottomLeft('Bottom left'),
  bottomRight('Bottom right');

  const OverlayCorner(this.label);

  final String label;
}

/// One person in the call panel.
///
/// [avatar] is a round PNG the runner caches under [id]; the caller sends it
/// once per picture and leaves it null afterwards. [avatarKey] names which
/// picture that is, and is what equality compares instead of the bytes.
class OverlayPanelRow {
  const OverlayPanelRow({
    required this.id,
    required this.name,
    this.speaking = false,
    this.muted = false,
    this.deafened = false,
    this.avatarKey,
    this.avatar,
  });

  final String id;
  final String name;
  final bool speaking;
  final bool muted;
  final bool deafened;
  final String? avatarKey;
  final Uint8List? avatar;

  /// The same row without picture bytes, once the runner holds them.
  OverlayPanelRow withoutAvatarBytes() => OverlayPanelRow(
        id: id,
        name: name,
        speaking: speaking,
        muted: muted,
        deafened: deafened,
        avatarKey: avatarKey,
      );

  Map<String, Object?> toJson() => {
        'id': id,
        'name': name,
        'speaking': speaking,
        'muted': muted,
        'deafened': deafened,
        if (avatar != null) 'avatar': avatar,
      };

  @override
  bool operator ==(Object other) =>
      other is OverlayPanelRow &&
      other.id == id &&
      other.name == name &&
      other.speaking == speaking &&
      other.muted == muted &&
      other.deafened == deafened &&
      other.avatarKey == avatarKey;

  @override
  int get hashCode =>
      Object.hash(id, name, speaking, muted, deafened, avatarKey);
}

/// The call panel the runner paints in one corner of one monitor. Value
/// equality is what lets the caller skip a repaint when nothing changed.
class OverlayPanel {
  const OverlayPanel({
    required this.monitor,
    required this.corner,
    required this.rows,
    required this.more,
    required this.surface,
    required this.border,
    required this.text,
    required this.textMuted,
    required this.accent,
    required this.danger,
  });

  /// Index into [OverlaySupport.monitors].
  final int monitor;
  final OverlayCorner corner;
  final List<OverlayPanelRow> rows;

  /// People past the rows shown.
  final int more;
  final Color surface, border, text, textMuted, accent, danger;

  OverlayPanel withRows(List<OverlayPanelRow> rows) => OverlayPanel(
        monitor: monitor,
        corner: corner,
        rows: rows,
        more: more,
        surface: surface,
        border: border,
        text: text,
        textMuted: textMuted,
        accent: accent,
        danger: danger,
      );

  Map<String, Object?> toJson() => {
        'monitor': monitor,
        'corner': corner.name,
        'rows': [for (final r in rows) r.toJson()],
        'more': more,
        'surface': surface.toARGB32(),
        'border': border.toARGB32(),
        'text': text.toARGB32(),
        'textMuted': textMuted.toARGB32(),
        'accent': accent.toARGB32(),
        'danger': danger.toARGB32(),
      };

  @override
  bool operator ==(Object other) =>
      other is OverlayPanel &&
      other.monitor == monitor &&
      other.corner == corner &&
      other.more == more &&
      other.surface == surface &&
      other.border == border &&
      other.text == text &&
      other.textMuted == textMuted &&
      other.accent == accent &&
      other.danger == danger &&
      listEquals(other.rows, rows);

  @override
  int get hashCode => Object.hash(
        monitor,
        corner,
        more,
        surface,
        border,
        text,
        textMuted,
        accent,
        danger,
        Object.hashAll(rows),
      );
}

/// The overlay window, behind a seam so the app never touches the channel.
abstract class ScreenOverlay {
  Future<OverlaySupport> support();

  /// Covers each of [monitors] (indexes into [OverlaySupport.monitors]); false
  /// when the window could not be made.
  Future<bool> show(List<int> monitors);

  Future<void> draw(List<OverlayShape> shapes);

  Future<void> hide();

  /// Paints [panel] in its corner of the window, or clears it when null.
  Future<void> panel(OverlayPanel? panel);

  /// The monitor the app's own window is on, or null when the runner cannot tell.
  Future<int?> appMonitor();
}
