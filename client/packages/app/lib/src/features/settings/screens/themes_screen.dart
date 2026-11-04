// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Appearance > Themes: built-in, personal and Space themes
/// (decision 0106).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/providers.dart';
import '../../../routing/routes.dart';
import '../providers/stored_theme.dart';
import '../providers/theme_store.dart';
import '../providers/theme_store_actions.dart';
import '../widgets/settings_empty.dart';
import '../widgets/settings_section_header.dart';
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

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } on api.ApiException catch (e) {
      _error = e.message;
    } catch (_) {
      _error = 'Something went wrong. Try again.';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _rowAction(api.SpaceTheme theme, ThemeRowAction action) {
    return _run(() async {
      switch (action) {
        case ThemeRowAction.setDefault:
          await setSpaceDefaultTheme(ref, theme.id);
        case ThemeRowAction.clearDefault:
          await setSpaceDefaultTheme(ref, null);
        case ThemeRowAction.remove:
          await removeStoreTheme(ref, theme.id);
      }
    });
  }

  Widget? _rowMenu(api.SpaceTheme theme, {required bool isDefault}) {
    final me = ref.read(meProvider).valueOrNull;
    final isAdmin = me?.permissions.hasPermission(Perm.manageServer) ?? false;
    final canRemove = isAdmin || (me != null && theme.authorId == me.id);
    if (!isAdmin && !canRemove) return null;
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
          ..._mineCard(),
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
            onApply: () => unawaited(
              ref.read(themeControllerProvider.notifier).select(choice),
            ),
          ),
      ],
    );
  }

  List<Widget> _mineCard() {
    final custom = ref.watch(customThemeProvider);
    if (custom == null) return const [];
    return [
      SettingsSectionCard(
        title: 'Mine',
        children: [
          ThemeListRow(
            key: const Key('theme-mine'),
            label: custom.name,
            preview: ThemePreview(colours: themeStrip(custom)),
            selected:
                ref.watch(themeControllerProvider) == AppThemeChoice.custom,
            onApply: () => unawaited(
              ref
                  .read(themeControllerProvider.notifier)
                  .select(AppThemeChoice.custom),
            ),
          ),
        ],
      ),
    ];
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
          : () => unawaited(_run(() => applyStoreTheme(ref, theme))),
      menu: _rowMenu(theme, isDefault: isDefault),
    );
  }
}
