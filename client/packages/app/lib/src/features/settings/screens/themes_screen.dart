// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Appearance > Themes: built-in, personal and Space themes, with
/// import, export and publishing in the header menu (decision 0106).
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
  List<String> _problems = const [];
  String? _error;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
      _problems = const [];
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

  Future<void> _pageAction(ThemePageAction action) async {
    final brightness = Theme.of(context).brightness;
    switch (action) {
      case ThemePageAction.import:
        return _import();
      case ThemePageAction.publish:
        return _run(
          () async => publishThemeDocument(
            ref,
            await currentThemeDocument(ref, brightness),
          ),
        );
      case ThemePageAction.export:
        return _run(
          () async =>
              saveThemeFile(await currentThemeDocument(ref, brightness)),
        );
    }
  }

  Future<void> _import() async {
    final parsed = await ref.read(themeFilePickerProvider)();
    final document = parsed?.document;
    if (parsed == null || !mounted) return;
    if (document == null) {
      setState(() => _problems = parsed.problems);
      return;
    }
    final canPublish = !ref.read(spaceThemesProvider).hasError;
    final choice = await showThemeImportSheet(
      context,
      document: document,
      canPublish: canPublish,
    );
    if (choice == null) return;
    await _run(() async {
      if (choice == ThemeImportChoice.publish) {
        await publishThemeDocument(ref, document);
        return;
      }
      await applyThemeDocument(
        ref,
        document,
        pictureBytes: document.picture?.data,
      );
    });
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
        case ThemeRowAction.export:
          final document = parseThemeJson(theme.theme).document;
          if (document != null) await saveThemeFile(document);
      }
    });
  }

  Widget _rowMenu(api.SpaceTheme theme, {required bool isDefault}) {
    final me = ref.read(meProvider).valueOrNull;
    final isAdmin = me?.permissions.hasPermission(Perm.manageServer) ?? false;
    return ThemeMenuButton<ThemeRowAction>(
      key: Key('theme-menu-${theme.id}'),
      semanticLabel: 'More for ${theme.name}',
      enabled: !_busy,
      onSelected: (action) => unawaited(_rowAction(theme, action)),
      items: (pick) => themeRowMenuItems(
        pick,
        isDefault: isDefault,
        canSetDefault: isAdmin,
        canRemove: isAdmin || (me != null && theme.authorId == me.id),
        canExport: parseThemeJson(theme.theme).document != null,
      ),
    );
  }

  Widget _mineMenu(ThemeDocument document) => ThemeMenuButton<ThemeRowAction>(
    key: const Key('theme-menu-mine'),
    semanticLabel: 'More for ${document.name}',
    enabled: !_busy,
    onSelected: (_) => unawaited(_run(() => saveThemeFile(document))),
    items: (pick) => themeRowMenuItems(
      pick,
      isDefault: false,
      canSetDefault: false,
      canRemove: false,
      canExport: true,
    ),
  );

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
      actions: [
        ThemeMenuButton<ThemePageAction>(
          key: const Key('themes-menu'),
          semanticLabel: 'Theme actions',
          enabled: !_busy,
          onSelected: (action) => unawaited(_pageAction(action)),
          items: (pick) =>
              themePageMenuItems(pick, storeAvailable: !storeFailed),
        ),
      ],
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
          if (_problems.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: AppSpacing.s8),
              child: AppErrorState(
                key: const Key('theme-import-problems'),
                message:
                    'That file is not a usable theme.\n${_problems.join('\n')}',
                onDismiss: () => setState(() => _problems = const []),
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
      topGap: _error == null && _problems.isEmpty ? 0 : kSettingsSectionTopGap,
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
            menu: _mineMenu(custom),
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
