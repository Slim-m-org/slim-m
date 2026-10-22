// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Presents the options of an [AppControlWithOptions]: the anchored menu on a
/// wide layout and the bottom sheet on a compact one, through the same
/// [ContextMenuRegion] every other menu here uses.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'context_menu_region.dart';
import 'control_swatch_row.dart';
import 'hover_reveal.dart';

/// One row of a control's options menu.
class ControlOption extends ControlOptionEntry {
  const ControlOption({
    required this.label,
    this.icon,
    required this.onSelected,
    this.tone = AppMenuItemTone.normal,
    this.selected = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback onSelected;
  final AppMenuItemTone tone;

  /// Marks the current value of a pick-one group; [AppMenuItem] adds the check.
  final bool selected;
}

/// A heading over the rows that follow it, to tell several pick-one groups
/// in one menu apart.
class ControlOptionHeading extends ControlOptionEntry {
  const ControlOptionHeading(this.text);

  final String text;
}

/// [child] with a caret and long-press that open [options].
///
/// An empty [options] draws [child] alone, so a caller can pass whatever is
/// currently possible without its own branch.
class ControlOptionsMenu extends StatefulWidget {
  const ControlOptionsMenu({
    super.key,
    required this.child,
    required this.options,
    required this.optionsLabel,
    this.active = false,
    this.destructive = false,
    this.caretHeight = AppSizes.controlMd,
    this.opensAbove = true,
    this.showCaret = true,
    this.menuWidth = 200,
  });

  /// False opens the options by long press or right-click alone, for a row
  /// with no width to spare for a caret.
  final bool showCaret;

  final Widget child;
  final List<ControlOptionEntry> options;
  final String optionsLabel;
  final bool active;

  /// Draws the caret in the danger outline of a destructive primary, such as a muted mic.
  final bool destructive;

  /// The caret's drawn height, matching a primary shorter than a full chip.
  final double caretHeight;

  /// Wider for options with long labels, such as device names.
  final double menuWidth;

  /// Opens the menu above the control; every caller lives in the bottom dock, which a menu must not cover.
  final bool opensAbove;

  @override
  State<ControlOptionsMenu> createState() => _ControlOptionsMenuState();
}

class _ControlOptionsMenuState extends State<ControlOptionsMenu> {
  final _region = GlobalKey<ContextMenuRegionState>();

  /// Keeps the control's focus and press state when options appear or go, as
  /// the share button does on starting a share with the keyboard.
  final _childKey = GlobalKey();

  /// Lets the caret count as inside the open menu's tap region, so a second press closes it.
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    final child = Listener(
      // The primary is outside the caret's group, so its own press closes an open menu here.
      onPointerDown: (_) => _region.currentState?.close(),
      child: KeyedSubtree(key: _childKey, child: widget.child),
    );
    // Looked up now: the menu reports closing from dispose, when this context can no longer be asked.
    final reveal = HoverRevealScope.maybeOf(context);
    if (widget.options.isEmpty) return child;
    return ContextMenuRegion(
      key: _region,
      // The wrapped control is already a tab stop, and owns the long-press.
      ownsFocusNode: false,
      enableLongPress: !widget.showCaret,
      opensAbove: widget.opensAbove,
      menuWidth: widget.menuWidth,
      tapRegionGroupId: _group,
      onOpenChanged: (open) => reveal?.pin(open),
      itemsBuilder: (context, close) => [
        for (final entry in widget.options) ..._rows(context, entry, close),
      ],
      child: widget.showCaret
          ? TapRegion(
              groupId: _group,
              child: AppControlWithOptions(
                active: widget.active,
                destructive: widget.destructive,
                visualHeight: widget.caretHeight,
                optionsLabel: widget.optionsLabel,
                onOpenOptions: () => _region.currentState?.toggle(),
                child: child,
              ),
            )
          : child,
    );
  }

  List<Widget> _rows(
    BuildContext context,
    ControlOptionEntry entry,
    VoidCallback close,
  ) {
    if (entry is ControlSwatchGroup) {
      return [
        AppMenuLabel(entry.heading),
        ControlSwatchRow(swatches: entry.swatches, close: close),
      ];
    }
    if (entry is ControlOptionHeading) return [AppMenuLabel(entry.text)];
    return _itemRows(context, entry as ControlOption, close);
  }

  List<Widget> _itemRows(
    BuildContext context,
    ControlOption option,
    VoidCallback close,
  ) => [
    AppMenuItem(
      label: option.label,
      leading: option.icon,
      tone: option.tone,
      selected: option.selected,
      onTap: () {
        close();
        option.onSelected();
      },
    ),
  ];
}
