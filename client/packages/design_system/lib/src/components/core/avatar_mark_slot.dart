// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The corner of an avatar a mark sits in: the picture with a circle cut out
/// and the mark drawn in the gap.
library;

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'avatar_geometry.dart';

/// [child] with [geometry]'s mark circle masked out, and [mark] centred in it.
///
/// Cut out rather than painted over, so the gap shows whatever surface the avatar sits on.
class AppAvatarMarkSlot extends StatelessWidget {
  const AppAvatarMarkSlot({
    super.key,
    required this.geometry,
    required this.mark,
    required this.child,
  });

  final AppAvatarGeometry geometry;
  final Widget mark;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final haloRadius = geometry.dotHaloRadius;
    final center = geometry.dotCenter;
    return SizedBox(
      width: geometry.size,
      height: geometry.size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          _MarkCutout(center: center, radius: haloRadius, child: child),
          Positioned(
            left: center.dx - haloRadius,
            top: center.dy - haloRadius,
            child: Padding(
              padding: const EdgeInsets.all(AppAvatarGeometry.dotHalo),
              child: mark,
            ),
          ),
        ],
      ),
    );
  }
}

/// The avatar minus the circle its presence mark sits in, masked rather than
/// clipped: a stencil clip is not anti-aliased on desktop GL, which is why
/// the avatar never clips.
class _MarkCutout extends SingleChildRenderObjectWidget {
  const _MarkCutout({
    required this.center,
    required this.radius,
    required super.child,
  });

  final Offset center;
  final double radius;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderMarkCutout(center, radius);

  @override
  void updateRenderObject(
      BuildContext context, _RenderMarkCutout renderObject) {
    renderObject
      ..center = center
      ..radius = radius;
  }
}

class _RenderMarkCutout extends RenderProxyBox {
  _RenderMarkCutout(this._center, this._radius);

  Offset _center;
  double _radius;

  set center(Offset value) {
    if (value == _center) return;
    _center = value;
    markNeedsPaint();
  }

  set radius(double value) {
    if (value == _radius) return;
    _radius = value;
    markNeedsPaint();
  }

  @override
  bool get alwaysNeedsCompositing => child != null;

  @override
  ShaderMaskLayer? get layer => super.layer as ShaderMaskLayer?;

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null) return;
    // A one-pixel ramp at the circle's edge is what keeps the cut anti-aliased.
    final outer = _center.distance + size.longestSide;
    final shader = ui.Gradient.radial(
      _center,
      outer,
      const [
        Color(0x00000000),
        Color(0x00000000),
        Color(0xFF000000),
        Color(0xFF000000),
      ],
      [0, (_radius - 0.5) / outer, (_radius + 0.5) / outer, 1],
    );
    layer = (layer ?? ShaderMaskLayer())
      ..shader = shader
      ..maskRect = offset & size
      ..blendMode = BlendMode.dstIn;
    context.pushLayer(layer!, super.paint, offset);
  }
}
