// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The editor's header with its overflow menu.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../providers/theme_draft.dart';
import 'settings_pane_body.dart' show kSettingsWidePaneInset;
import 'settings_sub_pages.dart';
import 'theme_draft_select.dart';
import 'theme_menu_region.dart';
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
    final header = ThemeDraftSelect(
      draft: draft,
      select: (d) => (saved: d.mineId != null, name: d.document.name.trim()),
      builder: (context, shown) => SettingsSubPageHeader(
        title: shown.saved ? 'Edit theme' : 'New theme',
        backLabel: 'Back to Themes',
        onBack: () => unawaited(SettingsSubPages.of(context).pop()),
        actions: [
          _menu(saved: shown.saved, name: shown.name),
          if (!wide) const SizedBox(width: AppSpacing.s4),
        ],
        onClose: SettingsSubPages.closeOf(context),
      ),
    );
    if (!wide) return header;
    const inset = kSettingsWidePaneInset;
    return Padding(
      padding: EdgeInsets.fromLTRB(inset.left, inset.top, inset.right, 0),
      child: header,
    );
  }

  Widget _menu({required bool saved, required String name}) => ThemeMenuRegion(
    enabled: !busy,
    sheetHeader: (_) => ThemeSheetTitle(
      name: name.isEmpty ? 'This theme' : name,
      caption: saved ? 'Mine' : 'Not saved',
      miniature: ListenableBuilder(
        listenable: draft,
        builder: (_, _) => ThemeMiniature.forDocument(draft.document),
      ),
    ),
    items: (_, close) => themeEditorMenuItems((action) {
      close();
      onAction(action);
    }, canDelete: saved),
    child: const ThemeMenuKebab(
      key: Key('theme-editor-menu'),
      label: 'More for this theme',
      card: false,
    ),
  );
}
