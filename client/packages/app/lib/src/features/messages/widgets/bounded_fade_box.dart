// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Clips a child taller than [BoundedFadeBox.maxHeight] and fades its last lines into [BoundedFadeBox.fadeColor].
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// Lets its child lay out at full height, then shows no more than [maxHeight] of it.
class BoundedFadeBox extends SingleChildRenderObjectWidget {
  const BoundedFadeBox({
    super.key,
    required this.maxHeight,
    required this.fadeColor,
    this.fadeHeight = 32,
    super.child,
  });

  final double maxHeight;

  /// The colour behind the child, so the fade reads as the text running out.
  final Color fadeColor;
  final double fadeHeight;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderBoundedFade(
    maxHeight: maxHeight,
    fadeColor: fadeColor,
    fadeHeight: fadeHeight,
  );

  @override
  void updateRenderObject(BuildContext context, _RenderBoundedFade render) {
    render
      ..maxHeight = maxHeight
      ..fadeColor = fadeColor
      ..fadeHeight = fadeHeight;
  }
}

class _RenderBoundedFade extends RenderShiftedBox {
  _RenderBoundedFade({
    required double maxHeight,
    required Color fadeColor,
    required double fadeHeight,
  }) : _maxHeight = maxHeight,
       _fadeColor = fadeColor,
       _fadeHeight = fadeHeight,
       super(null);

  double _maxHeight;
  Color _fadeColor;
  double _fadeHeight;
  bool _overflows = false;

  set maxHeight(double value) {
    if (value == _maxHeight) return;
    _maxHeight = value;
    markNeedsLayout();
  }

  set fadeColor(Color value) {
    if (value == _fadeColor) return;
    _fadeColor = value;
    markNeedsPaint();
  }

  set fadeHeight(double value) {
    if (value == _fadeHeight) return;
    _fadeHeight = value;
    markNeedsPaint();
  }

  @override
  void performLayout() {
    final child = this.child;
    if (child == null) {
      size = constraints.smallest;
      return;
    }
    child.layout(
      constraints.copyWith(minHeight: 0, maxHeight: double.infinity),
      parentUsesSize: true,
    );
    _overflows = child.size.height > _maxHeight;
    size = constraints.constrain(
      Size(child.size.width, math.min(child.size.height, _maxHeight)),
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final child = this.child;
    if (child == null) return;
    if (!_overflows) return context.paintChild(child, offset);
    context.pushClipRect(needsCompositing, offset, Offset.zero & size, (
      context,
      offset,
    ) {
      context.paintChild(child, offset);
      final band = Rect.fromLTWH(
        offset.dx,
        offset.dy + size.height - _fadeHeight,
        size.width,
        _fadeHeight,
      );
      context.canvas.drawRect(
        band,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_fadeColor.withValues(alpha: 0), _fadeColor],
          ).createShader(band),
      );
    });
  }
}
