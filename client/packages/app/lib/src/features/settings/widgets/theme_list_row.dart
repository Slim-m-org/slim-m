// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One theme on the Themes page: a preview, its name, and an optional menu.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class ThemeListRow extends StatelessWidget {
  const ThemeListRow({
    super.key,
    required this.label,
    required this.preview,
    required this.selected,
    required this.onApply,
    this.isSpaceDefault = false,
    this.onMenu,
  });

  final String label;
  final Widget preview;
  final bool selected;
  final bool isSpaceDefault;
  final VoidCallback onApply;

  /// Null for a theme with nothing to do beyond applying it.
  final VoidCallback? onMenu;

  static const Key defaultBadgeKey = Key('theme-store-default-badge');
  static const Key menuButtonKey = Key('theme-row-menu');

  @override
  Widget build(BuildContext context) => AppListRow(
    label: label,
    leading: preview,
    selected: selected,
    trailing: isSpaceDefault
        ? const AppBadge(
            key: defaultBadgeKey,
            variant: AppBadgeVariant.tag,
            label: 'Space default',
          )
        : null,
    trailingExtra: onMenu == null
        ? null
        : AppIconButton(
            key: menuButtonKey,
            icon: AppIcons.moreVertical,
            semanticLabel: 'More for $label',
            tooltip: 'More',
            onPressed: onMenu,
          ),
    onTap: onApply,
  );
}
