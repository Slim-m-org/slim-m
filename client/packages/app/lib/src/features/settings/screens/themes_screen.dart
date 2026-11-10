// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Appearance > Themes: built-in, personal and Space themes
/// (decision 0106).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../api_failure.dart';
import '../../../permissions.dart';
import '../../../providers/providers.dart';
import '../../../routing/routes.dart';
import '../providers/stored_theme.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_store.dart';
import '../providers/theme_store_actions.dart';
import '../widgets/settings_empty.dart';
import '../widgets/settings_section_header.dart';
import '../widgets/my_themes_card.dart';
import '../widgets/theme_list_row.dart';
import '../widgets/theme_menu_button.dart';
import '../widgets/theme_menus.dart';
import '../widgets/theme_preview.dart';
import '../widgets/theme_swatch.dart';
import 'settings_screen_scaffold.dart';

const _builtIn = [
  AppThemeChoice.system,
  AppThemeChoice.dark,
  AppThemeChoice.softDark,
  AppThemeChoice.light,
  AppThemeChoice.trueBlack,
  AppThemeChoice.catppuccin,
  AppThemeChoice.forest,
  AppThemeChoice.halloween,
];

class ThemesScreen extends ConsumerStatefulWidget {
  const ThemesScreen({super.key});

  @override
  ConsumerState<ThemesScreen> createState() => _ThemesScreenState();
}

class _ThemesScreenState extends ConsumerState<ThemesScreen> {
  String? _error;
  bool _busy = false;

  Future<void> _run(String whatFailed, Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e, stack) {
      _error = reportFailureSentence(api.LogTag.ui, whatFailed, e, stack);
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _rowAction(api.SpaceTheme theme, ThemeRowAction action) {
    final whatFailed = switch (action) {
      ThemeRowAction.copy => 'copy the theme',
      ThemeRowAction.setDefault => 'set the default theme',
      ThemeRowAction.clearDefault => 'clear the default theme',
      ThemeRowAction.remove => 'remove the theme',
    };
    return _run(whatFailed, () async {
      switch (action) {
        case ThemeRowAction.copy:
          _editCopyOf(theme);
        case ThemeRowAction.setDefault:
          await setSpaceDefaultTheme(ref, theme.id);
        case ThemeRowAction.clearDefault:
          await setSpaceDefaultTheme(ref, null);
        case ThemeRowAction.remove:
          await removeStoreTheme(ref, theme.id);
      }
    });
  }

  void _editCopyOf(api.SpaceTheme theme) {
    final document = parseThemeJson(theme.theme).document;
    if (document == null) return;
    unawaited(_openEditor(document, theme.name));
  }

  Future<void> _openEditor(ThemeDocument source, String name) {
    final copy = source.copyWith(name: themeCopyName(name), author: '');
    return context.push(
      Routes.personalThemeEditor,
      extra: ThemeEditorSeed(copy),
    );
  }

  Widget? _builtInMenu(AppThemeChoice choice) {
    final base = themeBaseOf(choice);
    if (base == null) return null;
    return ThemeMenuButton<ThemeRowAction>(
      key: Key('theme-builtin-menu-${choice.name}'),
      semanticLabel: 'More for ${themeLabel(choice)}',
      onSelected: (_) {
        final source = ThemeEditorSeed.fromBase(base).document;
        unawaited(_openEditor(source, themeLabel(choice)));
      },
      items: (pick) => themeRowMenuItems(pick, copyLabel: 'Customise'),
    );
  }

  Widget _rowMenu(api.SpaceTheme theme, {required bool isDefault}) {
    final me = ref.read(meProvider).valueOrNull;
    final isAdmin = me?.permissions.hasPermission(Perm.manageServer) ?? false;
    final canRemove = isAdmin || (me != null && theme.authorId == me.id);
    return ThemeMenuButton<ThemeRowAction>(
      key: Key('theme-menu-${theme.id}'),
      semanticLabel: 'More for ${theme.name}',
      enabled: !_busy,
      onSelected: (action) => unawaited(_rowAction(theme, action)),
      items: (pick) => themeRowMenuItems(
        pick,
        isDefault: isDefault,
        canSetDefault: isAdmin,
        canRemove: canRemove,
        copyLabel: 'Edit a copy',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final store = ref.watch(spaceThemesProvider);
    final storeFailed = store.hasError && !store.hasValue;
    // Watched so the first menu already knows who may remove and set the default.
    ref.watch(meProvider);
    return SettingsScreenScaffold(
      title: 'Themes',
      backTooltip: 'Back to Appearance',
      backFallback: Routes.personalSettingsPane('appearance'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: AppErrorState(
                message: _error!,
                onDismiss: () => setState(() => _error = null),
              ),
            ),
          _builtInCard(),
          MyThemesCard(
            onError: (message) => setState(() => _error = message),
            busy: _busy,
          ),
          _spaceCard(store, storeFailed),
        ],
      ),
    );
  }

  Widget _builtInCard() {
    // With no Space default to follow, that choice paints as System.
    final followsNothing =
        ref.watch(themeControllerProvider) == AppThemeChoice.spaceDefault &&
        ref.watch(spaceDefaultThemeProvider) == null;
    final current = followsNothing
        ? AppThemeChoice.system
        : ref.watch(themeControllerProvider);
    return SettingsSectionCard(
      title: 'Built in',
      topGap: _error == null ? 0 : kSettingsSectionTopGap,
      children: [
        for (final choice in _builtIn)
          ThemeListRow(
            key: Key('theme-builtin-${choice.name}'),
            label: themeLabel(choice),
            preview: ThemeSwatch(choice: choice),
            selected: current == choice,
            menu: _builtInMenu(choice),
            onApply: () => unawaited(
              ref.read(themeControllerProvider.notifier).select(choice),
            ),
          ),
      ],
    );
  }

  Widget _spaceCard(AsyncValue<api.SpaceThemeList> store, bool storeFailed) {
    final defaultId = store.valueOrNull?.defaultThemeId;
    final themes = store.valueOrNull?.themes ?? const <api.SpaceTheme>[];
    final followed = ref.watch(spaceDefaultThemeProvider);
    final current = ref.watch(themeControllerProvider);
    return SettingsSectionCard(
      title: 'Space',
      children: [
        if (storeFailed)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              key: const Key('themes-store-error'),
              message: 'Could not load the Space themes.',
              onRetry: () => ref.invalidate(spaceThemesProvider),
            ),
          ),
        if (store.hasValue && themes.isEmpty)
          const SettingsEmptyLine(
            'No shared themes yet.',
            key: Key('theme-store-empty'),
          ),
        if (followed != null)
          ThemeListRow(
            key: const Key('theme-follow-space'),
            label: themeLabel(AppThemeChoice.spaceDefault),
            preview: ThemePreview(colours: themeStrip(followed)),
            selected: current == AppThemeChoice.spaceDefault,
            onApply: () => unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .select(AppThemeChoice.spaceDefault),
            ),
          ),
        for (final theme in themes)
          _storeRow(
            theme,
            theme.id == defaultId,
            reserveThumbnail: themes.any((t) => t.hasPicture),
          ),
      ],
    );
  }

  Widget _storeRow(
    api.SpaceTheme theme,
    bool isDefault, {
    required bool reserveThumbnail,
  }) {
    final document = parseThemeJson(theme.theme).document;
    return ThemeListRow(
      key: Key('theme-store-${theme.id}'),
      label: theme.name,
      preview: document == null
          ? SizedBox(
              width: reserveThumbnail ? themePreviewWidth : themeSwatchWidth,
            )
          : ThemePreview(
              colours: themeStrip(document),
              pictureId: theme.hasPicture ? theme.id : null,
              reserveThumbnail: reserveThumbnail,
            ),
      selected: false,
      isSpaceDefault: isDefault,
      onApply: document == null || _busy
          ? () {}
          : () => unawaited(
              _run('apply the theme', () => applyStoreTheme(ref, theme)),
            ),
      menu: _rowMenu(theme, isDefault: isDefault),
    );
  }
}
