// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Appearance's Theme card: a live preview of the theme in use, its name and
/// where it came from with its one main action, Browse themes, the recent
/// themes one tap away, Follow Space default and High contrast.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/appearance_theme_summary.dart';
import '../providers/display_preferences.dart';
import '../providers/my_themes.dart';
import '../providers/recent_themes.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_gallery.dart';
import '../providers/theme_gallery_actions.dart';
import '../providers/theme_source.dart';
import 'appearance_recent_row.dart';
import 'settings_beside_or_below.dart';
import 'settings_control_column.dart';
import 'settings_search.dart';
import 'settings_section_header.dart';
import 'settings_sub_pages.dart';
import 'settings_toggle_row.dart';
import 'theme_editor_page.dart';
import 'theme_gallery.dart';
import 'theme_miniature.dart';

class AppearanceThemeCard extends ConsumerStatefulWidget {
  const AppearanceThemeCard({super.key});

  static const heroKey = Key('appearance-theme-hero');

  /// On what repaints while a Recent tile is previewed, and nothing else.
  static const heroHostKey = Key('appearance-theme-hero-host');
  static const browseKey = Key('appearance-browse-themes');
  static const actionKey = Key('appearance-theme-action');
  static const followLabel = 'Follow Space default';

  @override
  ConsumerState<AppearanceThemeCard> createState() =>
      _AppearanceThemeCardState();
}

class _AppearanceThemeCardState extends ConsumerState<AppearanceThemeCard> {
  late final _actions = ThemeGalleryActions(ref);
  final _preview = RecentThemePreview();

  /// A failure left over from the gallery belongs to that page, not this card.
  ThemeGalleryError? _inherited;

  @override
  void initState() {
    super.initState();
    _inherited = ref.read(themeGalleryStatusProvider).error;
  }

  @override
  void dispose() {
    _preview.dispose();
    super.dispose();
  }

  void _openEditor(ThemeEditorSeed seed) {
    final pages = SettingsSubPages.of(context);
    pages.push(themesSubPage());
    pages.push(themeEditorSubPage(seed));
  }

  VoidCallback? _actionFor(ThemeMainAction action, AppliedTheme applied) {
    final document = applied.document;
    switch (action) {
      case ThemeMainAction.customise:
        final seed = customiseSeed(applied.choice);
        return seed == null ? null : () => _openEditor(seed);
      case ThemeMainAction.edit:
        final id = switch (applied.source) {
          MineThemeSource(:final id) => id,
          _ => null,
        };
        final mine = ref
            .read(myThemesProvider)
            .where((t) => t.id == id)
            .firstOrNull;
        if (mine == null) return null;
        return () => _openEditor(ThemeEditorSeed(mine.document, mineId: id));
      case ThemeMainAction.saveToMine:
        if (document == null) return null;
        return () => unawaited(_actions.saveToMine(document));
    }
  }

  @override
  Widget build(BuildContext context) {
    final applied = ref.watch(appliedThemeProvider);
    final gallery = ref.watch(themeGalleryProvider);
    final status = ref.watch(themeGalleryStatusProvider);
    final summary = summariseTheme(applied, ref.watch(myThemesProvider));
    final recents = ref.watch(shownRecentThemesProvider);
    final followable = followableSpaceDefault(gallery);
    final enabled = !status.busy;
    return LayoutBuilder(
      builder: (context, box) {
        final wide = SettingsControlColumn.besideAt(box.maxWidth);
        final columns = wide ? 5 : 4;
        final tiles = recentThemeTiles(gallery, recents, max: columns);
        return SettingsSectionCard(
          title: 'Theme',
          children: [
            _Hero(
              look: appliedThemeTokens(applied),
              highContrast: ref.watch(highContrastControllerProvider),
              preview: _preview,
            ),
            SettingsHighlightTarget(
              label: 'Browse themes',
              child: _Identity(
                summary: summary,
                wide: wide,
                busy: status.busy,
                action: summary.action == null
                    ? null
                    : _actionFor(summary.action!, applied),
                onBrowse: () =>
                    SettingsSubPages.of(context).push(themesSubPage()),
              ),
            ),
            if (status.error case final error? when error != _inherited)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s16),
                child: AppErrorState(
                  key: const Key('appearance-theme-error'),
                  message: error.message,
                  detail: error.detail,
                  onDismiss: ref
                      .read(themeGalleryStatusProvider.notifier)
                      .dismiss,
                ),
              ),
            if (tiles.length > 1)
              AppearanceRecentRow(
                tiles: tiles,
                columns: columns,
                enabled: enabled,
                onApply: (entry) => unawaited(_actions.apply(entry)),
                preview: _preview,
              ),
            if (followable != null)
              SettingsToggleRow(
                label: AppearanceThemeCard.followLabel,
                description:
                    'Use ${followable.name} and keep up with its changes.',
                value: applied.following,
                semanticLabel: AppearanceThemeCard.followLabel,
                onChanged: (on) => unawaited(_actions.follow(on, followable)),
              ),
            SettingsToggleRow(
              label: 'High contrast',
              description: 'Stronger borders and text.',
              value: ref.watch(highContrastControllerProvider),
              semanticLabel: 'High contrast',
              onChanged: (next) => ref
                  .read(highContrastControllerProvider.notifier)
                  .select(next),
            ),
          ],
        );
      },
    );
  }
}

/// The theme in use as a short stretch of a real channel, or the Recent tile
/// being previewed; nothing else on the card repaints with it.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.look,
    required this.highContrast,
    required this.preview,
  });

  final ({AppTokens tokens, AppTokens? split}) look;
  final bool highContrast;
  final RecentThemePreview preview;

  AppTokens _contrast(AppTokens tokens) =>
      highContrast ? applyHighContrast(tokens) : tokens;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<ThemeGalleryEntry?>(
        key: AppearanceThemeCard.heroHostKey,
        valueListenable: preview,
        builder: (context, previewing, _) {
          final tokens = previewing?.tokens ?? look.tokens;
          final split = previewing == null ? look.split : previewing.split;
          return Stack(
            children: [
              ThemeMiniature(
                key: AppearanceThemeCard.heroKey,
                tokens: _contrast(tokens),
                split: split == null ? null : _contrast(split),
                detail: ThemeMiniatureDetail.hero,
              ),
              if (previewing != null)
                Positioned(
                  top: AppSpacing.s8,
                  right: AppSpacing.s8,
                  child: _PreviewingTag(name: previewing.name),
                ),
            ],
          );
        },
      );
}

/// The pill that says the hero shows a theme that is not in use yet.
class _PreviewingTag extends StatelessWidget {
  const _PreviewingTag({required this.name});

  final String name;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return DecoratedBox(
      key: const Key('appearance-theme-previewing'),
      decoration: BoxDecoration(
        color: tokens.surfaceRaised,
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: BorderRadius.circular(AppRadii.control),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s8,
          vertical: AppSpacing.s4,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          spacing: AppSpacing.s4,
          children: [
            Icon(
              AppIcons.preview,
              size: AppSizes.icon12,
              color: tokens.textSecondary,
            ),
            Text(
              'Previewing $name',
              style: AppText.micro.copyWith(
                color: tokens.textPrimary,
                fontWeight: AppWeights.semi,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The name, where it came from or Not saved, the main action and Browse
/// themes; below the control column's width the buttons take a line of their
/// own, half each.
class _Identity extends StatelessWidget {
  const _Identity({
    required this.summary,
    required this.wide,
    required this.busy,
    required this.action,
    required this.onBrowse,
  });

  final ThemeSummary summary;
  final bool wide;
  final bool busy;
  final VoidCallback? action;
  final VoidCallback onBrowse;

  static const _labels = {
    ThemeMainAction.customise: ('Customise', AppIcons.edit),
    ThemeMainAction.edit: ('Edit', AppIcons.edit),
    ThemeMainAction.saveToMine: ('Save to Mine', AppIcons.check),
  };

  List<Widget> _buttons({required bool full}) {
    final main = summary.action;
    final touch = full ? true : null;
    return [
      if (main != null && action != null)
        AppButton(
          key: AppearanceThemeCard.actionKey,
          label: _labels[main]!.$1,
          icon: _labels[main]!.$2,
          full: full,
          touch: touch,
          busy: busy && main == ThemeMainAction.saveToMine,
          onPressed: () {
            if (!busy) action!();
          },
        ),
      AppButton(
        key: AppearanceThemeCard.browseKey,
        label: 'Browse themes',
        trailingIcon: AppIcons.chevronRight,
        full: full,
        touch: touch,
        onPressed: onBrowse,
      ),
    ];
  }

  /// Half the line each, except that neither is cut short while the other
  /// has room to give, as CSS `flex: 1` shares a line.
  Widget _halves(List<Widget> buttons) {
    if (buttons.length == 1) return buttons.single;
    const share = IntrinsicColumnWidth(flex: 1);
    return Table(
      columnWidths: const {
        0: share,
        1: FixedColumnWidth(AppSpacing.s8),
        2: share,
      },
      children: [
        TableRow(children: [buttons.first, const SizedBox(), buttons.last]),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final source = summary.source;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      spacing: 2,
      children: [
        Text(
          summary.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.ui.copyWith(
            color: tokens.textPrimary,
            fontWeight: AppWeights.semi,
          ),
        ),
        if (source == null)
          const AppBadge(variant: AppBadgeVariant.warn, label: 'Not saved')
        else
          Text(
            source,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
      ],
    );
    if (!wide) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(
          AppSpacing.s16,
          AppSpacing.s12,
          AppSpacing.s16,
          AppSpacing.s16,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: AppSpacing.s12,
          children: [text, _halves(_buttons(full: true))],
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: AppCardRowScope.minHeight),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.s16,
          vertical: AppSpacing.s8,
        ),
        child: SettingsBesideOrBelow(
          minLeadWidth: 160,
          children: [
            text,
            Row(
              mainAxisSize: MainAxisSize.min,
              spacing: AppSpacing.s8,
              children: _buttons(full: false),
            ),
          ],
        ),
      ),
    );
  }
}
