// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space's theme store in Appearance: its themes with a preview, apply,
/// remove and "Make Space default", and export, import and publish.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../permissions.dart';
import '../../../providers/providers.dart';
import '../providers/theme_store.dart';
import '../providers/theme_store_actions.dart';
import 'settings_detail_row.dart';
import 'settings_section_header.dart';
import 'theme_swatch.dart';

class ThemeStoreCard extends ConsumerStatefulWidget {
  const ThemeStoreCard({super.key});

  @override
  ConsumerState<ThemeStoreCard> createState() => _ThemeStoreCardState();
}

class _ThemeStoreCardState extends ConsumerState<ThemeStoreCard> {
  ThemeDocument? _imported;
  List<String> _problems = const [];
  String? _error;
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
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

  Future<void> _import() async {
    final parsed = await ref.read(themeFilePickerProvider)();
    if (parsed == null || !mounted) return;
    setState(() {
      _imported = parsed.document;
      _problems = parsed.problems;
    });
  }

  Future<void> _export() => _run(() async {
    final brightness = Theme.of(context).brightness;
    await saveThemeFile(await currentThemeDocument(ref, brightness));
  });

  Future<void> _publishCurrent() => _run(() async {
    final brightness = Theme.of(context).brightness;
    await publishThemeDocument(
      ref,
      await currentThemeDocument(ref, brightness),
    );
  });

  Future<void> _publishImported() => _run(() async {
    final document = _imported;
    if (document != null) await publishThemeDocument(ref, document);
  });

  Future<void> _applyImported() => _run(() async {
    final document = _imported;
    if (document == null) return;
    await applyThemeDocument(
      ref,
      document,
      pictureBytes: document.picture?.data,
    );
    if (mounted) setState(() => _imported = null);
  });

  @override
  Widget build(BuildContext context) {
    final list = ref.watch(spaceThemesProvider);
    final me = ref.watch(meProvider).valueOrNull;
    final isAdmin = me?.permissions.hasPermission(Perm.manageServer) ?? false;
    final themes = list.valueOrNull?.themes ?? const <api.SpaceTheme>[];
    final defaultId = list.valueOrNull?.defaultThemeId;
    return SettingsSectionCard(
      title: 'Theme store',
      description: 'Themes shared in this Space.',
      children: [
        if (list.hasError && !list.hasValue)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              message: 'Could not load the theme store.',
              onRetry: () => ref.invalidate(spaceThemesProvider),
            ),
          ),
        if (list.hasValue && themes.isEmpty)
          const Padding(
            padding: EdgeInsets.all(AppSpacing.s16),
            child: Text('No shared themes yet.', key: Key('theme-store-empty')),
          ),
        for (final theme in themes)
          _StoreThemeRow(
            theme: theme,
            isDefault: theme.id == defaultId,
            canRemove: isAdmin || (me != null && theme.authorId == me.id),
            canSetDefault: isAdmin,
            busy: _busy,
            onApply: () => _run(() => applyStoreTheme(ref, theme)),
            onRemove: () => _run(() => removeStoreTheme(ref, theme.id)),
            onDefault: () => _run(
              () => setSpaceDefaultTheme(
                ref,
                theme.id == defaultId ? null : theme.id,
              ),
            ),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(message: _error!),
          ),
        _action(
          'Publish current theme',
          'Share it with this Space.',
          'Publish',
          _publishCurrent,
        ),
        _action(
          'Export current theme',
          'Save it as a file.',
          'Export',
          _export,
        ),
        _action('Import a theme', 'Open a theme file.', 'Import', _import),
        if (_problems.isNotEmpty)
          Padding(
            padding: const EdgeInsets.all(AppSpacing.s16),
            child: AppErrorState(
              key: const Key('theme-import-problems'),
              message:
                  'That file is not a usable theme.\n${_problems.join('\n')}',
            ),
          ),
        if (_imported != null) _importedRow(_imported!),
      ],
    );
  }

  Widget _action(
    String title,
    String detail,
    String label,
    VoidCallback onTap,
  ) => SettingsDetailRow(
    title: title,
    detail: detail,
    trailing: AppButton(
      label: label,
      size: AppButtonSize.sm,
      disabled: _busy,
      onPressed: onTap,
    ),
  );

  Widget _importedRow(ThemeDocument document) => SettingsDetailRow(
    key: const Key('theme-import-ready'),
    leading: _Preview(colours: _strip(document)),
    title: document.name,
    detail: 'Ready to use.',
    stackTrailingWhenNarrow: true,
    trailing: Wrap(
      spacing: AppSpacing.s8,
      runSpacing: AppSpacing.s8,
      children: [
        AppButton(
          label: 'Apply',
          size: AppButtonSize.sm,
          disabled: _busy,
          onPressed: _applyImported,
        ),
        AppButton(
          label: 'Publish',
          size: AppButtonSize.sm,
          disabled: _busy,
          onPressed: _publishImported,
        ),
        AppButton(
          label: 'Dismiss',
          size: AppButtonSize.sm,
          variant: AppButtonVariant.ghost,
          onPressed: () => setState(() => _imported = null),
        ),
      ],
    ),
  );
}

/// The swatch, a gap and a thumbnail, so every row's text starts at one edge.
const _previewWidth = 36.0 + AppSpacing.s8 + AppSizes.icon32;

List<Color> _strip(ThemeDocument d) => [
  d.colours['surfaceBase']!,
  d.colours['accent']!,
  d.colours['textPrimary']!,
];

class _StoreThemeRow extends ConsumerWidget {
  const _StoreThemeRow({
    required this.theme,
    required this.isDefault,
    required this.canRemove,
    required this.canSetDefault,
    required this.busy,
    required this.onApply,
    required this.onRemove,
    required this.onDefault,
  });

  final api.SpaceTheme theme;
  final bool isDefault;
  final bool canRemove;
  final bool canSetDefault;
  final bool busy;
  final VoidCallback onApply;
  final VoidCallback onRemove;
  final VoidCallback onDefault;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final document = parseThemeJson(theme.theme).document;
    return SettingsDetailRow(
      key: Key('theme-store-${theme.id}'),
      leading: document == null
          ? null
          : _Preview(
              colours: _strip(document),
              pictureId: theme.hasPicture ? theme.id : null,
            ),
      title: theme.name,
      badge: isDefault
          ? const AppBadge(
              key: Key('theme-store-default-badge'),
              variant: AppBadgeVariant.tag,
              label: 'Space default',
            )
          : null,
      detail: theme.authorName.isEmpty ? null : 'By ${theme.authorName}',
      stackTrailingWhenNarrow: true,
      trailing: Wrap(
        spacing: AppSpacing.s8,
        runSpacing: AppSpacing.s8,
        children: [
          AppButton(
            label: 'Apply',
            size: AppButtonSize.sm,
            disabled: busy || document == null,
            onPressed: onApply,
          ),
          if (canSetDefault)
            AppButton(
              label: isDefault ? 'Clear default' : 'Make Space default',
              size: AppButtonSize.sm,
              disabled: busy,
              onPressed: onDefault,
            ),
          if (canRemove)
            AppButton(
              label: 'Remove',
              size: AppButtonSize.sm,
              variant: AppButtonVariant.danger,
              disabled: busy,
              onPressed: onRemove,
            ),
        ],
      ),
    );
  }
}

/// A theme's three colours and, when it has one, a thumbnail of its picture.
class _Preview extends ConsumerWidget {
  const _Preview({required this.colours, this.pictureId});

  final List<Color> colours;
  final String? pictureId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final picture = pictureId == null
        ? null
        : ref.watch(spaceThemePictureProvider(pictureId!)).valueOrNull;
    return SizedBox(
      width: _previewWidth,
      child: Row(
        spacing: AppSpacing.s8,
        children: [
          ThemeSwatch(choice: AppThemeChoice.custom, colors: colours),
          if (pictureId != null)
            DecoratedBox(
              key: const Key('theme-preview-picture'),
              position: DecorationPosition.foreground,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(AppRadii.control / 2),
                border: Border.all(color: tokens.borderStrong),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadii.control / 2),
                child: SizedBox.square(
                  dimension: AppSizes.icon32,
                  child: picture == null
                      ? ColoredBox(color: tokens.surfaceSunken)
                      : Image.memory(
                          picture,
                          fit: BoxFit.cover,
                          gaplessPlayback: true,
                        ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
