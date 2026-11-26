// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bar of style controls over a selected note or text box: one colour button and the text size.
///
/// The colour button opens a popover holding every colour group the object takes, so a note and a text box show
/// the same bar shape. It floats above the object on a wide pane and docks at the foot of a narrow one.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_swatch_row.dart';

/// Below this pane width the bar docks instead of floating (desktop-vs-mobile Law 1: width decides).
const double canvasSelectionBarDockWidth = 600;

/// The widest the bar is ever drawn, however much room the pane has.
const double canvasSelectionBarMaxWidth = 480;

class CanvasSelectionBar extends StatelessWidget {
  const CanvasSelectionBar({
    super.key,
    required this.colour,
    required this.colourLabel,
    required this.colourEntries,
    required this.size,
    this.groupId,
    this.onClosed,
  });

  /// The colour the button shows for what the object has now.
  final Color colour;
  final String colourLabel;

  /// What the popover holds: colour groups and, for a note, how much of the fill shows.
  final List<ControlOptionEntry> colourEntries;
  final ControlSegmented size;

  /// The text field's tap region group, so a tap on the bar or its popover is not an outside tap that ends the edit.
  final Object? groupId;

  /// Runs when the colour menu or sheet closes however it ends, so a caller typing can take the keyboard back.
  final VoidCallback? onClosed;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final touch = AppTouchTargets.of(context);
    final rowHeight = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
    final bar = ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: canvasSelectionBarMaxWidth),
      child: Container(
        height: rowHeight + AppSpacing.s8,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          border: Border.all(color: tokens.borderSubtle),
          borderRadius: BorderRadius.circular(AppRadii.card),
          boxShadow: AppShadows.menu,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s8,
          children: [
            _ColourButton(
              colour: colour,
              label: colourLabel,
              entries: colourEntries,
              groupId: groupId,
              onClosed: onClosed,
            ),
            AppSegmentedControl.inline(
              options: size.options,
              selectedIndex: size.selectedIndex,
              onSegmentSelected: size.onSelected,
              semanticLabel: size.label,
            ),
          ],
        ),
      ),
    );
    return Material(
      type: MaterialType.transparency,
      child: groupId == null
          ? bar
          : TextFieldTapRegion(groupId: groupId, child: bar),
    );
  }
}

/// The swatch of the colour in use, which opens the colour popover.
class _ColourButton extends StatefulWidget {
  const _ColourButton({
    required this.colour,
    required this.label,
    required this.entries,
    required this.groupId,
    required this.onClosed,
  });

  final Color colour;
  final String label;
  final List<ControlOptionEntry> entries;
  final Object? groupId;
  final VoidCallback? onClosed;

  @override
  State<_ColourButton> createState() => _ColourButtonState();
}

class _ColourButtonState extends State<_ColourButton> {
  final _region = GlobalKey<ContextMenuRegionState>();

  List<Widget> _items(BuildContext context, VoidCallback close) {
    Widget inGroup(Widget child) => widget.groupId == null
        ? child
        : TextFieldTapRegion(groupId: widget.groupId, child: child);
    return [
      for (final entry in widget.entries)
        switch (entry) {
          ControlSwatchGroup(:final heading, :final swatches) => inGroup(
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (heading != null) AppMenuLabel(heading),
                ControlSwatchRow(swatches: swatches, close: close),
              ],
            ),
          ),
          ControlSegmented(
            :final label,
            :final options,
            :final selectedIndex,
            :final onSelected,
          ) =>
            inGroup(
              AppMenuSegmentedRow(
                label: label,
                options: options,
                selectedIndex: selectedIndex,
                onSelected: (i) {
                  close();
                  onSelected(i);
                },
              ),
            ),
          _ => const SizedBox.shrink(),
        },
    ];
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      enableLongPress: false,
      menuWidth: 248,
      tapRegionGroupId: widget.groupId,
      onVisibilityChanged: (open) {
        if (!open) widget.onClosed?.call();
      },
      itemsBuilder: _items,
      sheetSemanticLabel: widget.label,
      child: Tooltip(
        message: widget.label,
        excludeFromSemantics: true,
        child: FocusableTapTarget(
          semanticLabel: widget.label,
          onTap: () => _region.currentState?.toggle(),
          builder: (context, focused, hovered) => Container(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            decoration: BoxDecoration(
              color: hovered ? tokens.surfaceSunken : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadii.control),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s4,
              children: [
                Container(
                  width: AppSizes.icon20,
                  height: AppSizes.icon20,
                  decoration: BoxDecoration(
                    color: widget.colour,
                    shape: BoxShape.circle,
                    border: Border.all(color: tokens.borderSubtle),
                  ),
                ),
                Icon(
                  AppIcons.chevronDown,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
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
