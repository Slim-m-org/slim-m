// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's header with its overflow menu, and the "Start from" choices.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../providers/my_themes.dart';
import '../providers/theme_draft.dart';
import 'settings_pane_body.dart' show kSettingsWidePaneInset;
import 'settings_sub_pages.dart';
import 'theme_menu_button.dart';
import 'theme_miniature.dart';
import 'theme_sheet_title.dart';

enum ThemeEditorAction { publish, export, delete }

List<Widget> themeEditorMenuItems(
  void Function(ThemeEditorAction) pick, {
  required bool canDelete,
}) => [
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
  if (canDelete) ...[
    const AppMenuDivider(),
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => pick(ThemeEditorAction.delete),
    ),
  ],
];

/// Back to Themes, the title, the kebab and, beside the nav, close: the row
/// every pane heading sits on, or the app bar on a phone.
class ThemeEditorHeader extends StatelessWidget {
  const ThemeEditorHeader({
    super.key,
    required this.draft,
    required this.busy,
    required this.onAction,
  });

  final ThemeDraft draft;
  final bool busy;
  final ValueChanged<ThemeEditorAction> onAction;

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= kSettingsTwoPaneWidth;
    final header = SettingsSubPageHeader(
      title: draft.mineId == null ? 'New theme' : 'Edit theme',
      backLabel: 'Back to Themes',
      onBack: () => unawaited(SettingsSubPages.of(context).pop()),
      actions: [
        _menu(),
        if (!wide) const SizedBox(width: AppSpacing.s4),
      ],
      onClose: SettingsSubPages.closeOf(context),
    );
    if (!wide) return header;
    const inset = kSettingsWidePaneInset;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset.left, inset.top, inset.right, 0),
      child: header,
    );
  }

  Widget _menu() {
    final doc = draft.document;
    final name = doc.name.trim();
    return ThemeMenuButton<ThemeEditorAction>(
      key: const Key('theme-editor-menu'),
      semanticLabel: 'More for this theme',
      enabled: !busy,
      sheetTitle: ThemeSheetTitle(
        name: name.isEmpty ? 'This theme' : name,
        caption: draft.mineId == null ? 'Not saved' : 'Mine',
        miniature: ThemeMiniature.forDocument(doc),
      ),
      onSelected: onAction,
      items: (pick) =>
          themeEditorMenuItems(pick, canDelete: draft.mineId != null),
    );
  }
}

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
