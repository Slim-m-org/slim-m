// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "Mine" card on the Themes page: themes made or imported on this
/// device, with new, import, edit, export, publish and delete.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart'
    show AppThemeChoice, themeControllerProvider;
import '../../../routing/routes.dart';
import '../../../widgets/run_guarded.dart';
import '../providers/my_themes.dart';
import '../providers/stored_theme.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_file_io.dart';
import '../providers/theme_store_actions.dart';
import 'settings_empty.dart';
import 'settings_section_header.dart';
import 'theme_list_row.dart';
import 'theme_menu_button.dart';
import 'theme_preview.dart';

enum MyThemeAction { edit, export, publish, delete, saveToMine }

List<Widget> _menuItems(
  void Function(MyThemeAction) pick, {
  required bool saved,
}) => [
  if (saved)
    AppMenuItem(
      label: 'Edit',
      leading: AppIcons.edit,
      onTap: () => pick(MyThemeAction.edit),
    )
  else
    AppMenuItem(
      label: 'Save to Mine',
      leading: AppIcons.check,
      onTap: () => pick(MyThemeAction.saveToMine),
    ),
  AppMenuItem(
    label: 'Publish to Space',
    leading: AppIcons.share,
    onTap: () => pick(MyThemeAction.publish),
  ),
  AppMenuItem(
    label: 'Export to file',
    leading: AppIcons.download,
    onTap: () => pick(MyThemeAction.export),
  ),
  if (saved)
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: () => pick(MyThemeAction.delete),
    ),
];

class MyThemesCard extends ConsumerWidget {
  const MyThemesCard({super.key, required this.onError, required this.busy});

  /// Where a failure is shown: the page's persistent error state.
  final ValueChanged<String> onError;
  final bool busy;

  Future<void> _import(BuildContext context, WidgetRef ref) async {
    final pick = await ref.read(themeFilePickerProvider)();
    if (pick == null) return;
    final parsed = readThemeFile(pick.bytes);
    final document = parsed.document;
    if (document == null) {
      final shown = parsed.problems.take(3).join(' ');
      final more = parsed.problems.length > 3
          ? ' And ${parsed.problems.length - 3} more.'
          : '';
      onError('Could not import ${pick.fileName}. $shown$more');
      return;
    }
    final id = await ref.read(myThemesProvider.notifier).save(document);
    if (id == null) {
      onError('This device holds $myThemesMax themes. Delete one first.');
    }
  }

  Future<void> _act(
    BuildContext context,
    WidgetRef ref,
    ThemeDocument document,
    String? id,
    MyThemeAction action,
  ) async {
    switch (action) {
      case MyThemeAction.edit:
        unawaited(
          context.push(
            Routes.personalThemeEditor,
            extra: ThemeEditorSeed(document, mineId: id),
          ),
        );
      case MyThemeAction.saveToMine:
        final saved = await ref.read(myThemesProvider.notifier).save(document);
        if (saved == null) {
          onError('This device holds $myThemesMax themes. Delete one first.');
        }
      case MyThemeAction.delete:
        await ref.read(myThemesProvider.notifier).remove(id!);
      case MyThemeAction.export:
        await _export(ref, document);
      case MyThemeAction.publish:
        final failure = await runGuarded(
          whatFailed: 'publish the theme',
          action: () => publishTheme(ref, document),
        );
        if (failure != null) onError(failure);
    }
  }

  Future<void> _export(WidgetRef ref, ThemeDocument document) async {
    try {
      await ref.read(themeFileSaverProvider)(
        themeFileName(document.name),
        utf8.encode(document.toJsonText()),
      );
    } on Object catch (error, stack) {
      api.reportFailure(
        api.LogTag.platform,
        'save the theme file',
        error,
        stack,
      );
      onError('Could not save the file.');
    }
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref,
    ThemeDocument document, {
    required String keyId,
    required String? id,
    required bool selected,
  }) => ThemeListRow(
    key: Key('theme-mine$keyId'),
    label: document.name,
    preview: ThemePreview(colours: themeStrip(document)),
    selected: selected,
    onApply: () => unawaited(applyThemeDocument(ref, document)),
    menu: ThemeMenuButton<MyThemeAction>(
      key: Key('theme-mine$keyId-menu'),
      semanticLabel: 'More for ${document.name}',
      enabled: !busy,
      onSelected: (a) => unawaited(_act(context, ref, document, id, a)),
      items: (pick) => _menuItems(pick, saved: id != null),
    ),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mine = ref.watch(myThemesProvider);
    final applied = ref.watch(customThemeProvider);
    final usingCustom =
        ref.watch(themeControllerProvider) == AppThemeChoice.custom;
    final appliedText = applied?.toJsonText();
    final unsaved =
        applied != null &&
        !mine.any((t) => t.document.toJsonText() == appliedText);
    return SettingsSectionCard(
      title: 'Mine',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s4,
        children: [
          AppButton(
            key: const Key('theme-import'),
            label: 'Import',
            variant: AppButtonVariant.ghost,
            size: AppButtonSize.sm,
            disabled: busy,
            onPressed: () => unawaited(_import(context, ref)),
          ),
          AppButton(
            key: const Key('theme-new'),
            label: 'New',
            variant: AppButtonVariant.secondary,
            size: AppButtonSize.sm,
            onPressed: () =>
                unawaited(context.push(Routes.personalThemeEditor)),
          ),
        ],
      ),
      children: [
        if (mine.isEmpty && !unsaved)
          const SettingsEmptyLine(
            'No themes of your own yet.',
            key: Key('theme-mine-empty'),
          ),
        if (unsaved)
          _row(
            context,
            ref,
            applied,
            keyId: '',
            id: null,
            selected: usingCustom,
          ),
        for (final t in mine)
          _row(
            context,
            ref,
            t.document,
            keyId: '-${t.id}',
            id: t.id,
            selected: usingCustom && t.document.toJsonText() == appliedText,
          ),
      ],
    );
  }
}
