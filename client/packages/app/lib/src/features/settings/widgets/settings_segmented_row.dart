// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A label (and optional description) with a segmented choice at its right
/// edge, the design's `.row` with a segmented control.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:slimm_design_system/design_system.dart';

import 'settings_section_header.dart';
import 'settings_select_row.dart';
import 'settings_search.dart';

class SettingsSegmentedRow<T> extends StatelessWidget {
  const SettingsSegmentedRow({
    super.key,
    required this.label,
    required this.value,
    required this.choices,
    required this.onChanged,
    this.description,
    this.footnote,
  });

  final String label;
  final String? description;
  final T value;
  final List<SettingsChoice<T>> choices;
  final ValueChanged<T> onChanged;

  /// Extra caption under the description, for a state the choice cannot show.
  final String? footnote;

  /// The least room the label keeps beside the control; with less, the
  /// control drops under it instead of squeezing it.
  static const minLabelWidth = 160.0;

  @override
  Widget build(BuildContext context) =>
      SettingsHighlightTarget(label: label, child: _content(context));

  Widget _content(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final metrics = SettingsRowMetrics.of(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: AppText.ui.copyWith(color: tokens.textPrimary)),
        for (final line in [description, footnote].nonNulls) ...[
          const SizedBox(height: 2),
          Text(
            line,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
      ],
    );
    final control = AppSegmentedControl.inline(
      semanticLabel: label,
      options: [for (final c in choices) AppSegmentedOption(label: c.label)],
      selectedIndex: choices.indexWhere((c) => c.value == value),
      onSegmentSelected: (i) => onChanged(choices[i].value),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: metrics.minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: metrics.inset,
          vertical: metrics.vertical,
        ),
        child: _BesideOrBelow(
          minLeadWidth: minLabelWidth,
          children: [text, control],
        ),
      ),
    );
  }
}

/// Lays [children] (a label, then its control) side by side when the control
/// at its natural width leaves the label [minLeadWidth], and stacked when it
/// does not: a fixed breakpoint cannot know how wide the control's own labels
/// are.
class _BesideOrBelow extends MultiChildRenderObjectWidget {
  const _BesideOrBelow({required this.minLeadWidth, required super.children})
    : assert(children.length == 2);

  final double minLeadWidth;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBesideOrBelow(minLeadWidth);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderBesideOrBelow renderObject,
  ) => renderObject.minLeadWidth = minLeadWidth;
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
