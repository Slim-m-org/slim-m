// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A row that shows as many whole children as fit, in order, and never a clipped one.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// Shows the longest prefix of [items] that fits, then the overflow chip for the rest.
///
/// The first item stays even when no chip fits beside it.
///
/// [overflowChips] holds one chip per possible hidden count: entry `h - 1` is drawn when the last `h` items are hidden.
class WholeFitRow extends MultiChildRenderObjectWidget {
  WholeFitRow({
    required List<Widget> items,
    required List<Widget> overflowChips,
    this.spacing = 0,
    super.key,
  }) : assert(items.length == overflowChips.length),
       super(children: [...items, ...overflowChips]);

  final double spacing;

  @override
  RenderWholeFitRow createRenderObject(BuildContext context) =>
      RenderWholeFitRow(spacing: spacing);

  @override
  void updateRenderObject(
    BuildContext context,
    RenderWholeFitRow renderObject,
  ) => renderObject.spacing = spacing;
}

class _Parent extends ContainerBoxParentData<RenderBox> {}

class RenderWholeFitRow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _Parent>,
        RenderBoxContainerDefaultsMixin<RenderBox, _Parent> {
  RenderWholeFitRow({required double spacing}) : _spacing = spacing;

  double _spacing;
  set spacing(double value) {
    if (value == _spacing) return;
    _spacing = value;
    markNeedsLayout();
  }

  List<RenderBox> _visible = const [];

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _Parent) child.parentData = _Parent();
  }

  List<RenderBox> get _all {
    final out = <RenderBox>[];
    for (var c = firstChild; c != null; c = childAfter(c)) {
      out.add(c);
    }
    return out;
  }

  double _gaps(int count) => count < 2 ? 0 : _spacing * (count - 1);

  /// The first item outranks the rest, so it outlives the overflow chip.
  List<RenderBox> _choose(
    List<RenderBox> all,
    double room,
    double Function(RenderBox) width,
  ) {
    final n = all.length ~/ 2;
    final options = <List<RenderBox>>[
      all.sublist(0, n),
      for (var shown = n - 1; shown >= 1; shown--)
        [...all.sublist(0, shown), all[n + (n - shown) - 1]],
      if (n > 0) [all.first],
      if (n > 0) [all[n + n - 1]],
    ];
    for (final parts in options) {
      final used =
          parts.fold<double>(0, (sum, c) => sum + width(c)) +
          _gaps(parts.length);
      if (used <= room) return parts;
    }
    return const [];
  }

  @override
  Size computeDryLayout(BoxConstraints constraints) {
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    final parts = _choose(
      _all,
      constraints.maxWidth,
      (c) => c.getDryLayout(loose).width,
    );
    return _sizeOf(parts, constraints, (c) => c.getDryLayout(loose));
  }

  Size _sizeOf(
    List<RenderBox> parts,
    BoxConstraints constraints,
    Size Function(RenderBox) size,
  ) {
    var width = _gaps(parts.length);
    var height = 0.0;
    for (final c in parts) {
      final s = size(c);
      width += s.width;
      if (s.height > height) height = s.height;
    }
    return constraints.constrain(Size(width, height));
  }

  @override
  void performLayout() {
    final loose = BoxConstraints(maxHeight: constraints.maxHeight);
    final all = _all;
    for (final c in all) {
      c.layout(loose, parentUsesSize: true);
    }
    _visible = _choose(all, constraints.maxWidth, (c) => c.size.width);
    size = _sizeOf(_visible, constraints, (c) => c.size);
    var x = 0.0;
    for (final c in _visible) {
      (c.parentData! as _Parent).offset = Offset(
        x,
        (size.height - c.size.height) / 2,
      );
      x += c.size.width + _spacing;
    }
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    for (final c in _visible) {
      context.paintChild(c, offset + (c.parentData! as _Parent).offset);
    }
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    for (final c in _visible.reversed) {
      final hit = result.addWithPaintOffset(
        offset: (c.parentData! as _Parent).offset,
        position: position,
        hitTest: (result, transformed) =>
            c.hitTest(result, position: transformed),
      );
      if (hit) return true;
    }
    return false;
  }

  @override
  void visitChildrenForSemantics(RenderObjectVisitor visitor) =>
      _visible.forEach(visitor);
}
