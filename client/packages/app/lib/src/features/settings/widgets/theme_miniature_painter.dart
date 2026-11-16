// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bars miniature: the app drawn as blocks and bars in a theme's own
/// colours, scaled by its width so a 48 px thumbnail and a gallery card are
/// the same picture.
library;

import 'package:flutter/rendering.dart';
import 'package:slimm_design_system/design_system.dart';

/// Which part of the miniature a pass paints, so a picture can sit between.
enum ThemeMiniatureLayer {
  /// Everything, for a miniature with no picture.
  all,

  /// The rail, the channel list and the chat's background.
  back,

  /// The chat's header, messages, composer and backdrop.
  front,
}

/// Proportions follow the mockup's `.mini`: rail 9%, list 27%, header 8.5%
/// and composer 7.5% of the width, every length a share of it.
abstract final class ThemeMiniatureGeometry {
  static const aspect = 16 / 10;
  static const rail = 0.09;
  static const list = 0.27;
  static const head = 0.085;
  static const composer = 0.075;

  /// Where the chat column starts, the picture's left edge.
  static double chatLeft(double width) => width * (rail + list);

  /// The selected channel row, for a test that samples its fill.
  static Rect selectedRow(Size size) {
    final c = size.width / 100;
    final top = c * 3 + c * 0.6 + c * 1.9 + c * 2.4 + c * 1.2;
    final left = size.width * rail + c * 2;
    final rowTop = top + (c * 5.4 + c * 1.2);
    return Rect.fromLTWH(left, rowTop, size.width * list - c * 4, c * 5.4);
  }

  /// The composer's send button.
  static Rect send(Size size) {
    final c = size.width / 100;
    final box = composerBox(size);
    final side = c * 4.6;
    return Rect.fromLTWH(
      box.right - c * 1.4 - side,
      box.center.dy - side / 2,
      side,
      side,
    );
  }

  static Rect composerBox(Size size) {
    final c = size.width / 100;
    final left = chatLeft(size.width) + c * 3;
    return Rect.fromLTRB(
      left,
      size.height - c * 3 - size.width * composer,
      size.width - c * 3,
      size.height - c * 3,
    );
  }
}

class ThemeMiniaturePainter extends CustomPainter {
  const ThemeMiniaturePainter({
    required this.tokens,
    this.split,
    this.layer = ThemeMiniatureLayer.all,
  });

  final AppTokens tokens;

  /// The second palette of a System miniature, painted right of a diagonal.
  final AppTokens? split;
  final ThemeMiniatureLayer layer;

  @override
  void paint(Canvas canvas, Size size) {
    _paintAll(canvas, size, tokens);
    final dark = split;
    if (dark == null) return;
    canvas.save();
    canvas.clipPath(
      Path()
        ..moveTo(size.width * 0.62, 0)
        ..lineTo(size.width, 0)
        ..lineTo(size.width, size.height)
        ..lineTo(size.width * 0.38, size.height)
        ..close(),
    );
    _paintAll(canvas, size, dark);
    canvas.restore();
  }

  void _paintAll(Canvas canvas, Size size, AppTokens t) {
    final m = _Mini(canvas, size, t);
    if (layer != ThemeMiniatureLayer.front) m.back();
    if (layer != ThemeMiniatureLayer.back) m.front();
  }

  @override
  bool shouldRepaint(ThemeMiniaturePainter oldDelegate) =>
      oldDelegate.tokens != tokens ||
      oldDelegate.split != split ||
      oldDelegate.layer != layer;
}

class _Mini {
  _Mini(this.canvas, this.size, this.t) : c = size.width / 100;

  final Canvas canvas;
  final Size size;
  final AppTokens t;

  /// One percent of the width, the unit every length is in.
  final double c;

  double get _railW => size.width * ThemeMiniatureGeometry.rail;
  double get _listW => size.width * ThemeMiniatureGeometry.list;
  double get _chatX => _railW + _listW;
  double get _chatW => size.width - _chatX;

  Paint _fill(Color colour) => Paint()..color = colour;

  Color _fade(Color colour, double opacity) =>
      colour.withValues(alpha: colour.a * opacity);

  void _edge(double x) => canvas.drawRect(
    Rect.fromLTWH(x - 1, 0, 1, size.height),
    _fill(t.borderSubtle),
  );

  void back() {
    canvas.drawRect(Offset.zero & size, _fill(t.surfaceBase));
    canvas.drawRect(
      Rect.fromLTWH(0, 0, _chatX, size.height),
      _fill(t.surfaceSunken),
    );
    _rail();
    _list();
    _edge(_railW);
    _edge(_chatX);
  }

  void front() {
    _backdrop();
    _head();
    _messages();
    _composer();
  }

  void _rail() {
    final side = c * 5.4;
    final x = (_railW - side) / 2;
    for (var i = 0; i < 3; i++) {
      final rect = Rect.fromLTWH(x, c * 3 + i * (side + c * 2), side, side);
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, Radius.circular(c * 1.6)),
        _fill(t.surfaceRaised),
      );
    }
  }

  void _list() {
    final left = _railW + c * 2;
    final inner = _listW - c * 4;
    var y = c * 3 + c * 0.6;
    _bar(left + c * 1.6, y, inner * 0.7, high: true);
    y += c * 1.9 + c * 2.4 + c * 1.2;
    const widths = [0.55, 0.65, 0.45, 0.6];
    for (var i = 0; i < widths.length; i++) {
      final row = Rect.fromLTWH(left, y, inner, c * 5.4);
      final selected = i == 1;
      if (selected) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(row, Radius.circular(c * 1.2)),
          _fill(t.accentSoft),
        );
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(row.left, row.top + c, c * 0.6, row.height - c * 2),
            Radius.circular(c),
          ),
          _fill(t.accent),
        );
      }
      final barW = (inner - c * 3.2) * widths[i];
      _bar(
        row.left + c * 1.6,
        row.center.dy - c * 0.8,
        barW,
        colour: selected ? t.textPrimary : null,
      );
      y += c * 5.4 + c * 1.2;
    }
  }

  void _head() {
    final h = size.width * ThemeMiniatureGeometry.head;
    canvas.drawRect(
      Rect.fromLTWH(_chatX, h - 1, _chatW, 1),
      _fill(t.borderSubtle),
    );
    _bar(_chatX + c * 3, h / 2 - c * 0.95, (_chatW - c * 6) * 0.3, high: true);
  }

  void _messages() {
    final avatar = c * 5;
    final left = _chatX + c * 3;
    final column = _chatW - c * 6 - avatar - c * 2;
    var y = size.width * ThemeMiniatureGeometry.head + c * 3;
    const messages = [
      [0.25, 0.85, 0.6],
      [0.3, 0.45],
      [0.2, 0.7],
    ];
    for (final (index, bars) in messages.indexed) {
      canvas.drawCircle(
        Offset(left + avatar / 2, y + avatar / 2),
        avatar / 2,
        _fill(_fade(t.textSecondary, 0.45)),
      );
      var by = y + c * 0.3;
      for (final (i, share) in bars.indexed) {
        final high = i == 0;
        _bar(
          left + avatar + c * 2,
          by,
          column * share,
          high: high,
          colour: index == 1 && i == 1 ? t.accent : null,
        );
        by += (high ? c * 1.9 : c * 1.6) + c * 1.3;
      }
      y = by - c * 1.3 + c * 3;
    }
  }

  void _composer() {
    final box = ThemeMiniatureGeometry.composerBox(size);
    final rrect = RRect.fromRectAndRadius(box, Radius.circular(c * 1.6));
    canvas.drawRRect(rrect, _fill(t.surfaceRaised));
    canvas.drawRRect(
      rrect.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = t.borderStrong,
    );
    _bar(
      box.left + c * 2.4,
      box.center.dy - c * 0.8,
      (box.width - c * 3.8) * 0.4,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        ThemeMiniatureGeometry.send(size),
        Radius.circular(c * 1.2),
      ),
      _fill(t.accentFill),
    );
  }

  /// The theme's cobweb in the chat's top right, from the mockup's 40-unit drawing.
  void _backdrop() {
    if (t.backdrop != AppBackdrop.halloweenWebs) return;
    final side = c * 24;
    final origin = Offset(
      size.width - side,
      size.width * ThemeMiniatureGeometry.head,
    );
    final k = side / 40;
    Offset p(double x, double y) => origin + Offset(x * k, y * k);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = (0.8 * k).clamp(0.5, 1.5)
      ..color = _fade(t.textSecondary, 0.4);
    final path = Path();
    for (final tip in const [
      (0.0, 0.0),
      (6.0, 16.0),
      (18.0, 30.0),
      (32.0, 40.0),
      (40.0, 40.0),
    ]) {
      path
        ..moveTo(p(40, 0).dx, p(40, 0).dy)
        ..lineTo(p(tip.$1, tip.$2).dx, p(tip.$1, tip.$2).dy);
    }
    void strand(List<double> d) {
      final a = p(d[0], d[1]);
      final b1 = p(d[2], d[3]);
      final b2 = p(d[4], d[5]);
      final c1 = p(d[6], d[7]);
      final c2 = p(d[8], d[9]);
      path
        ..moveTo(a.dx, a.dy)
        ..quadraticBezierTo(b1.dx, b1.dy, b2.dx, b2.dy)
        ..quadraticBezierTo(c1.dx, c1.dy, c2.dx, c2.dy);
    }

    strand(const [30, 0, 31, 6, 35.5, 8, 37, 13, 40, 12]);
    strand(const [20, 0, 22, 10, 30, 14, 33, 22, 40, 24]);
    strand(const [10, 0, 13, 12, 22, 20, 28, 30, 40, 34]);
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(_chatX, 0, _chatW, size.height));
    canvas.drawPath(path, paint);
    canvas.restore();
  }

  void _bar(
    double x,
    double y,
    double width, {
    bool high = false,
    Color? colour,
  }) {
    final h = high ? c * 1.9 : c * 1.6;
    final fill =
        colour ??
        (high ? _fade(t.textPrimary, 0.95) : _fade(t.textSecondary, 0.7));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, h),
        Radius.circular(h / 2),
      ),
      _fill(fill),
    );
  }
}
