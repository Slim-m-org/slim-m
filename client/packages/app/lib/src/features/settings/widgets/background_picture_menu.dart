// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menu the background row opens: choose a photo, browse files, or none.
///
/// One `showAppSheet` call, so it is a bottom sheet under `kCompactWidth` and
/// the floating menu above it (rule 3 of `docs/design/desktop-vs-mobile.md`).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

enum BackgroundPictureAction { choose, browse, remove }

Future<BackgroundPictureAction?> showBackgroundPictureMenu(
  BuildContext context, {
  required bool canRemove,
}) {
  return showAppSheet<BackgroundPictureAction>(
    context,
    bare: true,
    builder: (sheetContext) {
      void pick(BackgroundPictureAction action) =>
          Navigator.of(sheetContext).pop(action);
      return AppSheetMenu(
        children: [
          AppMenuItem(
            label: 'Choose photo',
            leading: AppIcons.image,
            onTap: () => pick(BackgroundPictureAction.choose),
          ),
          AppMenuItem(
            label: 'Browse files',
            leading: AppIcons.attachFile,
            onTap: () => pick(BackgroundPictureAction.browse),
          ),
          if (canRemove)
            AppMenuItem(
              label: 'None',
              leading: AppIcons.imageMissing,
              onTap: () => pick(BackgroundPictureAction.remove),
            ),
        ],
      );
    },
  );
}
