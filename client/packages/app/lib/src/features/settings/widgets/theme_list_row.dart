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
    this.menu,
  });

  final String label;
  final Widget preview;
  final bool selected;
  final bool isSpaceDefault;
  final VoidCallback onApply;

  /// Null for a theme with nothing to do beyond applying it.
  final Widget? menu;

  static const Key defaultBadgeKey = Key('theme-store-default-badge');

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
    trailingExtra: menu,
    onTap: onApply,
  );
}
