// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's overflow menu, the "Start from" choices and its confirm sheet.
library;

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/my_themes.dart';

enum ThemeEditorAction { apply, publish, export, delete }

List<Widget> themeEditorMenuItems(
  void Function(ThemeEditorAction) pick, {
  required bool canDelete,
}) => [
  AppMenuItem(
    label: 'Save and apply',
    leading: AppIcons.check,
    onTap: () => pick(ThemeEditorAction.apply),
  ),
  AppMenuItem(
    label: 'Publish to Space',
    leading: AppIcons.share,
    onTap: () => pick(ThemeEditorAction.publish),
  ),
  AppMenuItem(
    label: 'Export to file',
    leading: AppIcons.download,
    onTap: () => pick(ThemeEditorAction.export),
  ),
  if (canDelete)
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => pick(ThemeEditorAction.delete),
    ),
];

class ThemeEditorSource {
  const ThemeEditorSource(this.key, this.label, this.document);

  final String key;
  final String label;
  final ThemeDocument document;
}

/// Every theme the editor can start from: built-in, then Mine, then the Space.
List<ThemeEditorSource> themeEditorSources({
  required List<MyTheme> mine,
  required List<api.SpaceTheme> space,
}) => [
  for (final entry in themeBases.entries)
    ThemeEditorSource(
      'base:${entry.key}',
      themeBaseLabels[entry.key]!,
      ThemeDocument.of(
        entry.value,
        name: themeBaseLabels[entry.key]!,
        author: '',
        base: entry.key,
        brightness: entry.key == 'light' ? Brightness.light : Brightness.dark,
      ),
    ),
  for (final t in mine)
    ThemeEditorSource('mine:${t.id}', '${t.document.name} (mine)', t.document),
  for (final t in space)
    if (parseThemeJson(t.theme).document case final document?)
      ThemeEditorSource('space:${t.id}', '${t.name} (Space)', document),
];

/// How a built-in preset is named where a person picks one.
const themeBaseLabels = {
  'dark': 'Dark',
  'light': 'Light',
  'trueBlack': 'True black',
  'catppuccin': 'Catppuccin',
  'softDark': 'Soft dark',
  'forest': 'Forest',
  'halloween': 'Halloween',
};

/// Asks before throwing something away; true when the person agrees.
Future<bool?> confirmThemeEditorSheet(
  BuildContext context, {
  required String title,
  required String action,
}) => showAppSheet<bool>(
  context,
  builder: (sheetContext) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s16,
      0,
      AppSpacing.s16,
      AppSpacing.s16,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: AppSpacing.s12,
      children: [
        Text(
          title,
          style: AppText.body.copyWith(
            color: Theme.of(sheetContext).extension<AppTokens>()!.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          spacing: AppSpacing.s8,
          children: [
            AppButton(
              label: 'Keep editing',
              variant: AppButtonVariant.ghost,
              onPressed: () => Navigator.of(sheetContext).pop(false),
            ),
            AppButton(
              key: const Key('theme-editor-confirm'),
              label: action,
              variant: AppButtonVariant.danger,
              onPressed: () => Navigator.of(sheetContext).pop(true),
            ),
          ],
        ),
      ],
    ),
  ),
);
