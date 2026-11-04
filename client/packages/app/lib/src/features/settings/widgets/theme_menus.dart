// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The row menu items on the Themes page.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum ThemeRowAction { setDefault, clearDefault, remove }

List<Widget> themeRowMenuItems(
  void Function(ThemeRowAction) pick, {
  required bool isDefault,
  required bool canSetDefault,
  required bool canRemove,
}) => [
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
