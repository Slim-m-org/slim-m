// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The personal background picture: one painted layer behind the shell, and
/// the scope that lets panes above it show through.
///
/// Policy and the contrast it guarantees live in `app_background_policy.dart`.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'app_background_policy.dart';

/// How a picture is treated before panes sit on it. [dim] is the wanted fade
/// toward the base surface, already clamped to what keeps text readable.
@immutable
class AppBackgroundStyle {
  const AppBackgroundStyle({
    required this.dim,
    required this.vignette,
    required this.blur,
  });

  final double dim;
  final bool vignette;

  /// 0 for sharp up to 1 for [maxBlurSigma].
  final double blur;

  static const maxBlurSigma = 20.0;

  @override
  bool operator ==(Object other) =>
      other is AppBackgroundStyle &&
      other.dim == dim &&
      other.vignette == vignette &&
      other.blur == blur;

  @override
  int get hashCode => Object.hash(dim, vignette, blur);
}

/// Tells panes below it how much of their own surface to keep, or, with a
/// null [paneAlpha], that nothing shows through.
class AppBackgroundScope extends InheritedWidget {
  const AppBackgroundScope({
    super.key,
    required this.paneAlpha,
    required super.child,
  });

  /// Panes' surfaces keep this much opacity over the picture.
  const AppBackgroundScope.active({super.key, required super.child})
      : paneAlpha = kBackgroundPaneAlpha;

  final double? paneAlpha;

  /// [surface] as a pane under this scope paints it: translucent over a
  /// picture, untouched otherwise.
  static Color paneColor(BuildContext context, Color surface) {
    final scope =
        context.dependOnInheritedWidgetOfExactType<AppBackgroundScope>();
    final alpha = scope?.paneAlpha;
    return alpha == null ? surface : surface.withValues(alpha: alpha);
  }

  /// Whether a picture is behind the panes here.
  static bool showingOf(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<AppBackgroundScope>()
          ?.paneAlpha !=
      null;

  @override
  bool updateShouldNotify(AppBackgroundScope old) => old.paneAlpha != paneAlpha;
}

/// Fills its box with [color] the way a pane paints it: translucent over a
/// background picture, plain otherwise.
class PaneSurface extends StatelessWidget {
  const PaneSurface({super.key, required this.color, required this.child});

  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: AppBackgroundScope.paneColor(context, color),
        child: child,
      );
}

/// Makes everything below opaque again: a drawer, sheet or menu that sits in
/// the shell's tree but floats over the panes.
class OpaquePanes extends StatelessWidget {
  const OpaquePanes({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => AppBackgroundScope.showingOf(context)
      ? AppBackgroundScope(paneAlpha: null, child: child)
      : child;
}

/// Paints [image] covering its box, faded toward [base], as a single layer
/// that repaints only when the picture or its style changes.
class AppBackgroundLayer extends StatelessWidget {
  const AppBackgroundLayer({
    super.key,
    required this.image,
    required this.style,
    required this.base,
  });

  final ui.Image image;
  final AppBackgroundStyle style;
  final Color base;

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: ExcludeSemantics(
          child: RepaintBoundary(
            child: CustomPaint(
              key: const Key('app_background_layer'),
              painter:
                  AppBackgroundPainter(image: image, style: style, base: base),
              size: Size.infinite,
            ),
          ),
        ),
      );
}

class AppBackgroundPainter extends CustomPainter {
  const AppBackgroundPainter({
    required this.image,
    required this.style,
    required this.base,
  });

  final ui.Image image;
  final AppBackgroundStyle style;
  final Color base;

  static const _vignetteStart = 0.4;
  static const _vignetteStrength = 0.85;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final bounds = Offset.zero & size;
    canvas.save();
    canvas.clipRect(bounds);
    _picture(canvas, size);
    canvas.drawRect(
      bounds,
      Paint()..color = base.withValues(alpha: style.dim),
    );
    if (style.vignette) _vignette(canvas, size, bounds);
    canvas.restore();
  }

  void _picture(Canvas canvas, Size size) {
    final iw = image.width.toDouble();
    final ih = image.height.toDouble();
    final scale = math.max(size.width / iw, size.height / ih);
    final cropW = size.width / scale;
    final cropH = size.height / scale;
    final source =
        Rect.fromLTWH((iw - cropW) / 2, (ih - cropH) / 2, cropW, cropH);
    final paint = Paint()..filterQuality = FilterQuality.medium;
    final sigma = style.blur * AppBackgroundStyle.maxBlurSigma;
    if (sigma > 0) {
      paint.imageFilter = ui.ImageFilter.blur(
        sigmaX: sigma,
        sigmaY: sigma,
        tileMode: TileMode.clamp,
      );
    }
    canvas.drawImageRect(image, source, Offset.zero & size, paint);
  }

  void _vignette(Canvas canvas, Size size, Rect bounds) {
    final reach =
        math.sqrt(size.width * size.width + size.height * size.height);
    final shader = ui.Gradient.radial(
      bounds.center,
      reach / 2,
      [
        base.withValues(alpha: 0),
        base.withValues(alpha: _vignetteStrength),
      ],
      [_vignetteStart, 1],
    );
    canvas.drawRect(bounds, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(AppBackgroundPainter old) =>
      old.image != image || old.style != style || old.base != base;
}
