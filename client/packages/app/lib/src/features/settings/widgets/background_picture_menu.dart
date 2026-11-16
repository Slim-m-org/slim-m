// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menu the background row opens: choose a photo, browse files, or none.
///
/// One `showAppSheet` call, so it is a titled bottom sheet under
/// `kCompactWidth` and the floating menu above it (rule 3 of
/// `docs/design/desktop-vs-mobile.md`).
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
      final menu = AppSheetMenu(
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
      if (MediaQuery.sizeOf(sheetContext).width >= kCompactWidth) return menu;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [const _SheetTitle(), menu],
      );
    },
  );
}

/// Names the sheet, which opens away from the row that asked for it.
class _SheetTitle extends StatelessWidget {
  const _SheetTitle();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.s4),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
        ),
        child: const AppSheetHeader(
          'Background picture',
          padding: EdgeInsets.fromLTRB(
            AppSpacing.s16,
            AppSpacing.s8,
            AppSpacing.s16,
            AppSpacing.s12,
          ),
        ),
      ),
    );
  }
}
