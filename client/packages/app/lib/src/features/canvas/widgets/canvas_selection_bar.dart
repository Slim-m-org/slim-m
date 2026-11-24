// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bar of controls over a selected canvas object: the option groups a tool offers, laid in one row.
///
/// It floats above the object on a wide pane and docks at the foot of a narrow one, and
/// scrolls sideways when the row is wider than the room.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';

/// Below this pane width the bar docks instead of floating (desktop-vs-mobile Law 1: width decides).
const double canvasSelectionBarDockWidth = 600;

/// The width one swatch takes in the bar's colour rows.
const double _swatchWidth = 30;
const double _touchScale = 1.4;

class CanvasSelectionBar extends StatelessWidget {
  const CanvasSelectionBar({
    super.key,
    required this.entries,
    this.trailing,
    this.groupId,
  });

  final List<ControlOptionEntry> entries;

  /// A control kept at the row's end, such as the emoji button while text is typed.
  final Widget? trailing;

  /// The text field's tap region group, so a tap on the bar is not an outside tap that ends the edit.
  final Object? groupId;

  /// The width the row takes unscrolled, which a scroll view cannot report for itself.
  double _naturalWidth(BuildContext context, bool touch) {
    var width = AppSpacing.s24 + (trailing == null ? 0 : AppSizes.rowTouch);
    for (final entry in entries) {
      width +=
          AppSpacing.s12 +
          switch (entry) {
            ControlSwatchGroup(:final swatches) => _groupWidth(swatches, touch),
            ControlSegmented(:final options) => AppSegmentedControl.inlineWidth(
              context,
              options,
            ),
            _ => 0,
          };
    }
    return width - AppSpacing.s12;
  }

  double _groupWidth(List<ControlSwatch> swatches, bool touch) =>
      swatches.length * _swatchWidth * (touch ? _touchScale : 1);

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final rowHeight = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    final bar = Container(
      height: rowHeight + AppSpacing.s8,
      width: _naturalWidth(context, touch),
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.card),
        boxShadow: AppShadows.menu,
      ),
      child: Row(
        children: [
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final (i, entry) in entries.indexed) ...[
                    if (i > 0) const SizedBox(width: AppSpacing.s12),
                    _entry(context, entry, touch),
                  ],
                ],
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: groupId == null
          ? bar
          : TextFieldTapRegion(groupId: groupId, child: bar),
    );
  }

  Widget _entry(BuildContext context, ControlOptionEntry entry, bool touch) =>
      switch (entry) {
        ControlSwatchGroup(:final heading, :final swatches) => Semantics(
          label: heading,
          container: true,
          child: SizedBox(
            width: _groupWidth(swatches, touch),
            child: ControlSwatchRow(swatches: swatches, close: () {}),
          ),
        ),
        ControlSegmented(
          :final label,
          :final options,
          :final selectedIndex,
          :final onSelected,
        ) =>
          AppSegmentedControl.inline(
            options: options,
            selectedIndex: selectedIndex,
            onSegmentSelected: onSelected,
            semanticLabel: label,
          ),
        _ => const SizedBox.shrink(),
      };
}

/// Puts a [CanvasSelectionBar] above [anchor] (below it when there is no room), kept inside the pane;
/// docked full width at the foot above the keyboard and the dock on a narrow pane.
class CanvasSelectionBarLayout extends SingleChildLayoutDelegate {
  const CanvasSelectionBarLayout({
    required this.anchor,
    required this.bottomInset,
  });

  /// The selected object on screen, in the pane's own coordinates.
  final Rect anchor;

  /// How far the foot of the pane is covered: the keyboard or the call dock.
  final double bottomInset;

  static const double _gap = AppSpacing.s8;

  bool _docked(Size size) => size.width < canvasSelectionBarDockWidth;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(0, constraints.maxWidth - _gap * 2),
        maxHeight: constraints.maxHeight,
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (_docked(size)) {
      return Offset(
        (size.width - childSize.width) / 2,
        size.height - bottomInset - childSize.height - _gap,
      );
    }
    final above = anchor.top - childSize.height - _gap;
    final top = above >= _gap
        ? above
        : math.min(
            anchor.bottom + _gap,
            size.height - bottomInset - childSize.height - _gap,
          );
    final left = (anchor.center.dx - childSize.width / 2)
        .clamp(_gap, math.max(_gap, size.width - childSize.width - _gap))
        .toDouble();
    return Offset(left, math.max(_gap, top));
  }

  @override
  bool shouldRelayout(CanvasSelectionBarLayout old) =>
      old.anchor != anchor || old.bottomInset != bottomInset;
}
