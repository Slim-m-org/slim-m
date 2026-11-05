// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row menu items on the Themes page.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum ThemeRowAction { copy, setDefault, clearDefault, remove }

List<Widget> themeRowMenuItems(
  void Function(ThemeRowAction) pick, {
  bool isDefault = false,
  bool canSetDefault = false,
  bool canRemove = false,
  String? copyLabel,
}) => [
  if (copyLabel != null)
    AppMenuItem(
      label: copyLabel,
      leading: AppIcons.edit,
      onTap: () => pick(ThemeRowAction.copy),
    ),
  if (canSetDefault)
    AppMenuItem(
      label: isDefault ? 'Clear default' : 'Set as Space default',
      leading: AppIcons.pin,
      onTap: () => pick(
        isDefault ? ThemeRowAction.clearDefault : ThemeRowAction.setDefault,
      ),
    ),
  if (canRemove)
    AppMenuItem(
      label: 'Remove',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => pick(ThemeRowAction.remove),
    ),
];
