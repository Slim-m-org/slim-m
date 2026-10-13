// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Presents the options of an [AppControlWithOptions]: the anchored menu on a
/// wide layout and the bottom sheet on a compact one, through the same
/// [ContextMenuRegion] every other menu here uses.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'context_menu_region.dart';
import 'control_swatch_row.dart';

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
    this.caretHeight = AppSizes.controlMd,
    this.opensAbove = false,
    this.showCaret = true,
  });

  /// False opens the options by long press or right-click alone, for a row
  /// with no width to spare for a caret.
  final bool showCaret;

  final Widget child;
  final List<ControlOptionEntry> options;
  final String optionsLabel;
  final bool active;

  /// The caret's drawn height, matching a primary shorter than a full chip.
  final double caretHeight;

  /// Opens the menu above the control, for one docked at the bottom edge.
  final bool opensAbove;

  @override
  State<ControlOptionsMenu> createState() => _ControlOptionsMenuState();
}

class _ControlOptionsMenuState extends State<ControlOptionsMenu> {
  final _region = GlobalKey<ContextMenuRegionState>();

  /// Keeps the control's focus and press state when options appear or go, as
  /// the share button does on starting a share with the keyboard.
  final _childKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final child = KeyedSubtree(key: _childKey, child: widget.child);
    if (widget.options.isEmpty) return child;
    return ContextMenuRegion(
      key: _region,
      // The wrapped control is already a tab stop, and owns the long-press.
      ownsFocusNode: false,
      enableLongPress: !widget.showCaret,
      opensAbove: widget.opensAbove,
      itemsBuilder: (context, close) => [
        for (final entry in widget.options) ..._rows(context, entry, close),
      ],
      child: widget.showCaret
          ? AppControlWithOptions(
              active: widget.active,
              visualHeight: widget.caretHeight,
              optionsLabel: widget.optionsLabel,
              onOpenOptions: () => _region.currentState?.open(),
              child: child,
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
