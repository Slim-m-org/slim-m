// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A "..." button whose menu drops from it on wide windows and lifts as a
/// bottom sheet on a phone (rule 3 of `docs/design/desktop-vs-mobile.md`).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/anchored_menu.dart';
import '../../../widgets/animated_menu_portal.dart';

class ThemeMenuButton<T> extends StatefulWidget {
  const ThemeMenuButton({
    super.key,
    required this.semanticLabel,
    required this.items,
    required this.onSelected,
    this.enabled = true,
  });

  final String semanticLabel;

  /// The menu rows; each calls the given function with its choice.
  final List<Widget> Function(void Function(T)) items;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  State<ThemeMenuButton<T>> createState() => _ThemeMenuButtonState<T>();
}

class _ThemeMenuButtonState<T> extends State<ThemeMenuButton<T>> {
  final _controller = AnimatedMenuController();

  void _pick(T value) {
    _controller.hide();
    widget.onSelected(value);
  }

  Future<void> _openSheet() async {
    final picked = await showAppSheet<T>(
      context,
      bare: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AppSheetMenu(
          children: widget.items((v) => Navigator.of(sheetContext).pop(v)),
        ),
      ),
    );
    if (picked != null && mounted) widget.onSelected(picked);
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kCompactWidth;
    return AnchoredMenu(
      controller: _controller,
      menu: AppMenu(width: 250, children: widget.items(_pick)),
      child: AppIconButton(
        icon: AppIcons.moreVertical,
        semanticLabel: widget.semanticLabel,
        tooltip: 'More',
        onPressed: !widget.enabled
            ? null
            : wide
            ? _controller.toggle
            : () => unawaited(_openSheet()),
      ),
    );
  }
}
