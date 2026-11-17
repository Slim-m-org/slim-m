// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A label and its control side by side while the label keeps its room, and
/// stacked when it would not.
library;

import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

/// Lays [children] (a label, then its control) side by side when the control
/// at its natural width leaves the label [minLeadWidth], and stacked when it
/// does not: a fixed breakpoint cannot know how wide the control's own labels
/// are.
class SettingsBesideOrBelow extends MultiChildRenderObjectWidget {
  const SettingsBesideOrBelow({
    super.key,
    required this.minLeadWidth,
    required super.children,
  }) : assert(children.length == 2);

  final double minLeadWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBesideOrBelow(minLeadWidth);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderBesideOrBelow).minLeadWidth = minLeadWidth;
}

class _RenderBesideOrBelow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, MultiChildLayoutParentData>,
        RenderBoxContainerDefaultsMixin<RenderBox, MultiChildLayoutParentData> {
  _RenderBesideOrBelow(this._minLeadWidth);

  static const _gap = AppSpacing.s16;
  static const _stackGap = AppSpacing.s8;

  double _minLeadWidth;
  set minLeadWidth(double value) {
    if (value == _minLeadWidth) return;
    _minLeadWidth = value;
    markNeedsLayout();
  }

  RenderBox get _lead => firstChild!;
  RenderBox get _trail => lastChild!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! MultiChildLayoutParentData) {
      child.parentData = MultiChildLayoutParentData();
    }
  }

  bool _beside(double width) =>
      width - _trail.getMaxIntrinsicWidth(double.infinity) - _gap >=
      _minLeadWidth;

  Size _layout(BoxConstraints constraints, {required bool dry}) {
    final width = constraints.maxWidth;
    Size measure(RenderBox child, BoxConstraints c) {
      if (dry) return child.getDryLayout(c);
      child.layout(c, parentUsesSize: true);
      return child.size;
    }

    final lead = _lead.parentData! as MultiChildLayoutParentData;
    final trail = _trail.parentData! as MultiChildLayoutParentData;
    if (_beside(width)) {
      final t = measure(_trail, BoxConstraints(maxWidth: width));
      final l = measure(
        _lead,
        BoxConstraints(minWidth: 0, maxWidth: width - t.width - _gap),
      );
      final height = math.max(l.height, t.height);
      if (!dry) {
        lead.offset = Offset(0, (height - l.height) / 2);
        trail.offset = Offset(width - t.width, (height - t.height) / 2);
      }
      return constraints.constrain(Size(width, height));
    }
    final l = measure(_lead, BoxConstraints(maxWidth: width));
    final t = measure(_trail, BoxConstraints(maxWidth: width));
    if (!dry) {
      lead.offset = Offset.zero;
      trail.offset = Offset(0, l.height + _stackGap);
    }
    return constraints.constrain(Size(width, l.height + _stackGap + t.height));
  }

  @override
  void performLayout() => size = _layout(constraints, dry: false);

  @override
  Size computeDryLayout(BoxConstraints constraints) =>
      _layout(constraints, dry: true);

  @override
  double computeMinIntrinsicWidth(double height) => math.max(
    _lead.getMinIntrinsicWidth(height),
    _trail.getMinIntrinsicWidth(height),
  );

  @override
  double computeMaxIntrinsicWidth(double height) =>
      _lead.getMaxIntrinsicWidth(height) +
      _gap +
      _trail.getMaxIntrinsicWidth(height);

  @override
  double computeMinIntrinsicHeight(double width) =>
      _layout(BoxConstraints(maxWidth: width), dry: true).height;

  @override
  double computeMaxIntrinsicHeight(double width) =>
      computeMinIntrinsicHeight(width);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
