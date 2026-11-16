// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one menu a theme opens, from its kebab, a right-click or a long press:
/// anchored under the kebab on a wide window, a sheet titled with the theme on
/// a phone (rule 3 of `docs/design/desktop-vs-mobile.md`).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import 'theme_gallery_frame.dart';

class ThemeMenuRegion extends StatefulWidget {
  const ThemeMenuRegion({
    super.key,
    required this.items,
    required this.enabled,
    required this.child,
    this.sheetHeader,
  });

  /// The rows, each given the callback that closes the menu; null opens none.
  final List<Widget> Function(BuildContext context, VoidCallback close)? items;

  /// False while an action runs: nothing opens, and the kebab keeps focus.
  final bool enabled;

  /// Names the theme above a phone's sheet.
  final WidgetBuilder? sheetHeader;
  final Widget child;

  @override
  State<ThemeMenuRegion> createState() => _ThemeMenuRegionState();
}

class _ThemeMenuRegionState extends State<ThemeMenuRegion> {
  final _region = GlobalKey<ContextMenuRegionState>();
  final _group = Object();

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    return _ThemeMenuScope(
      region: _region,
      group: _group,
      child: ContextMenuRegion(
        key: _region,
        ownsFocusNode: false,
        menuWidth: 250,
        tapRegionGroupId: _group,
        itemsBuilder: (context, close) =>
            items == null || !widget.enabled ? const [] : items(context, close),
        sheetHeaderBuilder: widget.sheetHeader,
        child: widget.child,
      ),
    );
  }
}

class _ThemeMenuScope extends InheritedWidget {
  const _ThemeMenuScope({
    required this.region,
    required this.group,
    required super.child,
  });

  final GlobalKey<ContextMenuRegionState> region;
  final Object group;

  @override
  bool updateShouldNotify(_ThemeMenuScope old) => false;
}

/// The kebab inside a [ThemeMenuRegion]: a press opens its menu under the
/// kebab, and a second press closes it.
class ThemeMenuKebab extends StatelessWidget {
  const ThemeMenuKebab({super.key, required this.label, this.card = true});

  /// What a screen reader hears: 'More for Forest'.
  final String label;

  /// A card's 28 px button; false is a page header's full-size one.
  final bool card;

  @override
  Widget build(BuildContext context) {
    final scope = context.getInheritedWidgetOfExactType<_ThemeMenuScope>();
    void toggle() {
      final box = context.findRenderObject() as RenderBox?;
      scope?.region.currentState?.toggle(
        at: box?.localToGlobal(Offset(0, box.size.height)),
      );
    }

    return TapRegion(
      groupId: scope?.group,
      child: card
          ? ThemeCardButton(
              icon: AppIcons.moreVertical,
              label: label,
              tooltip: 'More',
              onPressed: toggle,
            )
          : AppIconButton(
              icon: AppIcons.moreVertical,
              semanticLabel: label,
              tooltip: 'More',
              onPressed: toggle,
            ),
    );
  }
}
