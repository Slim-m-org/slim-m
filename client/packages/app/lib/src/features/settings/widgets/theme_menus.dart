// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The menu items and the import confirmation on the Themes page.
///
/// The import confirmation is one `showAppSheet`, a bottom sheet under
/// `kCompactWidth` and a dialog above it (rule 3 of `docs/design/desktop-vs-mobile.md`).
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_preview.dart';

enum ThemeRowAction { setDefault, clearDefault, remove, export }

enum ThemePageAction { import, publish, export }

enum ThemeImportChoice { apply, publish }

List<Widget> themeRowMenuItems(
  void Function(ThemeRowAction) pick, {
  required bool isDefault,
  required bool canSetDefault,
  required bool canRemove,
  required bool canExport,
}) => [
  if (canSetDefault)
    AppMenuItem(
      label: isDefault ? 'Clear default' : 'Set as Space default',
      leading: AppIcons.pin,
      onTap: () => pick(
        isDefault ? ThemeRowAction.clearDefault : ThemeRowAction.setDefault,
      ),
    ),
  if (canExport)
    AppMenuItem(
      label: 'Export',
      leading: AppIcons.download,
      onTap: () => pick(ThemeRowAction.export),
    ),
  if (canRemove)
    AppMenuItem(
      label: 'Remove',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => pick(ThemeRowAction.remove),
    ),
];

List<Widget> themePageMenuItems(
  void Function(ThemePageAction) pick, {
  required bool storeAvailable,
}) => [
  AppMenuItem(
    label: 'Import file',
    leading: AppIcons.attachFile,
    onTap: () => pick(ThemePageAction.import),
  ),
  if (storeAvailable)
    AppMenuItem(
      label: 'Publish current theme',
      leading: AppIcons.share,
      onTap: () => pick(ThemePageAction.publish),
    ),
  AppMenuItem(
    label: 'Export current theme',
    leading: AppIcons.download,
    onTap: () => pick(ThemePageAction.export),
  ),
];

/// Null when cancelled.
Future<ThemeImportChoice?> showThemeImportSheet(
  BuildContext context, {
  required ThemeDocument document,
  required bool canPublish,
}) => showAppSheet<ThemeImportChoice>(
  context,
  builder: (sheetContext) {
    final tokens = Theme.of(sheetContext).extension<AppTokens>()!;
    void pop([ThemeImportChoice? choice]) =>
        Navigator.of(sheetContext).pop(choice);
    return Padding(
      key: const Key('theme-import-ready'),
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        0,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: AppSpacing.s16,
        children: [
          Text(
            'Use this theme?',
            style: AppText.body.copyWith(
              color: tokens.textPrimary,
              fontWeight: AppWeights.semi,
            ),
          ),
          Row(
            spacing: AppSpacing.s12,
            children: [
              ThemePreview(colours: themeStrip(document)),
              Expanded(
                child: Text(
                  document.name,
                  style: AppText.body.copyWith(color: tokens.textPrimary),
                ),
              ),
            ],
          ),
          Wrap(
            spacing: AppSpacing.s8,
            runSpacing: AppSpacing.s8,
            alignment: WrapAlignment.end,
            children: [
              AppButton(
                label: 'Cancel',
                variant: AppButtonVariant.ghost,
                onPressed: pop,
              ),
              if (canPublish)
                AppButton(
                  label: 'Publish',
                  variant: AppButtonVariant.secondary,
                  onPressed: () => pop(ThemeImportChoice.publish),
                ),
              AppButton(
                label: 'Apply',
                onPressed: () => pop(ThemeImportChoice.apply),
              ),
            ],
          ),
        ],
      ),
    );
  },
);
