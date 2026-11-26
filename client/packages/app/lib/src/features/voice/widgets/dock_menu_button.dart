// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A dock button that opens a menu on a plain press: the anchored popover on a
/// wide window and a bottom sheet on a compact one (desktop-vs-mobile.md rule 3).
library;

import 'package:flutter/material.dart';

import '../../../widgets/context_menu_region.dart';
import '../../../widgets/hover_reveal.dart';
import 'call_dock_button.dart';

class DockMenuButton extends StatefulWidget {
  const DockMenuButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.itemsBuilder,
    required this.sheetLabel,
    this.active = false,
    this.menuWidth = 240,
    this.onOpenChanged,
  });

  final IconData icon;
  final String tooltip;
  final bool active;
  final double menuWidth;

  /// Told when the menu opens and closes.
  final ValueChanged<bool>? onOpenChanged;

  /// Names the compact sheet for a screen reader.
  final String sheetLabel;

  final List<Widget> Function(BuildContext context, VoidCallback close)
  itemsBuilder;

  @override
  State<DockMenuButton> createState() => _DockMenuButtonState();
}

class _DockMenuButtonState extends State<DockMenuButton> {
  final _region = GlobalKey<ContextMenuRegionState>();

  /// Lets the button count as inside the open menu's tap region, so a second press closes it.
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    // Looked up now: the menu reports closing from dispose, when this context can no longer be asked.
    final reveal = HoverRevealScope.maybeOf(context);
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      enableLongPress: false,
      opensAbove: true,
      menuWidth: widget.menuWidth,
      tapRegionGroupId: _group,
      onOpenChanged: (open) {
        reveal?.pin(open);
        widget.onOpenChanged?.call(open);
      },
      sheetSemanticLabel: widget.sheetLabel,
      itemsBuilder: widget.itemsBuilder,
      child: TapRegion(
        groupId: _group,
        child: CallDockButton(
          icon: widget.icon,
          tooltip: widget.tooltip,
          active: widget.active,
          onPressed: () => _region.currentState?.toggle(),
        ),
      ),
    );
  }
}
