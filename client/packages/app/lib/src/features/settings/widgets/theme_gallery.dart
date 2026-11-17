// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Settings > Appearance > Themes, a page inside the Appearance pane: a grid
/// of live miniatures for the built-in, Mine and Space themes, one tap to
/// apply (decision 0106).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show meProvider;
import '../providers/my_themes.dart';
import '../providers/theme_draft.dart';
import '../providers/theme_gallery.dart';
import '../providers/theme_gallery_actions.dart';
import '../providers/theme_store.dart';
import 'settings_sub_pages.dart';
import 'theme_editor_page.dart';
import 'theme_gallery_card.dart';
import 'theme_gallery_layout.dart';
import 'theme_gallery_menu.dart';
import 'theme_gallery_section_header.dart';
import 'theme_gallery_unsaved_card.dart';

/// The Themes page, opened from Appearance's Browse themes or `?page=themes`.
SettingsSubPage themesSubPage() => SettingsSubPage(
  id: 'themes',
  title: 'Themes',
  backLabel: 'Back to Appearance',
  urlId: 'themes',
  builder: (_) => const ThemeGalleryPage(),
);

const _filters = {
  ThemeGalleryFilter.all: 'All',
  ThemeGalleryFilter.builtIn: 'Built in',
  ThemeGalleryFilter.mine: 'Mine',
  ThemeGalleryFilter.space: 'Space',
};

typedef _CardBuilder =
    Widget Function(ThemeGalleryEntry entry, Key key, {Key? menuKey});

class ThemeGalleryPage extends ConsumerStatefulWidget {
  const ThemeGalleryPage({super.key});

  @override
  ConsumerState<ThemeGalleryPage> createState() => _ThemeGalleryPageState();
}

class _ThemeGalleryPageState extends ConsumerState<ThemeGalleryPage> {
  late final _actions = ThemeGalleryActions(
    ProviderScope.containerOf(context, listen: false),
  );
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  /// A failure shows at the top, so the page goes there to show it.
  void _showError(ThemeGalleryStatus? before, ThemeGalleryStatus now) {
    if (now.error == null || now.error == before?.error) return;
    if (!_scroll.hasClients || _scroll.offset == 0) return;
    final duration = AppMotion.reduced(context, AppMotion.slow);
    if (duration == Duration.zero) {
      _scroll.jumpTo(0);
    } else {
      unawaited(
        _scroll.animateTo(0, duration: duration, curve: AppMotion.entrance),
      );
    }
  }

  void _openEditor(ThemeEditorSeed? seed) =>
      SettingsSubPages.of(context).push(themeEditorSubPage(seed));

  @override
  Widget build(BuildContext context) {
    final gallery = ref.watch(themeGalleryProvider);
    ref.watch(spaceThemePictureHoldProvider);
    final status = ref.watch(themeGalleryStatusProvider);
    ref.listen(themeGalleryStatusProvider, _showError);
    final filter = ref.watch(themeGalleryFilterProvider);
    final menu = ThemeGalleryMenu(
      actions: _actions,
      me: ref.watch(meProvider).valueOrNull,
      openEditor: _openEditor,
    );
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final layout = ThemeGalleryLayout(box.maxWidth, scaler);
        final enabled = !status.busy;
        Widget card(ThemeGalleryEntry entry, Key key, {Key? menuKey}) =>
            ThemeGalleryCard(
              key: key,
              entry: entry,
              width: layout.cardWidth,
              enabled: enabled,
              onApply: () => unawaited(_actions.apply(entry)),
              onCustomise: _customise(entry),
              menuItems: menu.itemsFor(entry),
              sheetHeader: (_) => menu.sheetHeader(entry),
              menuKey: menuKey,
            );
        return CustomScrollView(
          key: const Key('themes-page-list'),
          controller: _scroll,
          slivers: [
            if (status.error case final error?)
              _box(
                Padding(
                  padding: const EdgeInsets.only(top: AppSpacing.s8),
                  child: AppErrorState(
                    key: const Key('themes-page-error'),
                    message: error.message,
                    detail: error.detail,
                    onDismiss: ref
                        .read(themeGalleryStatusProvider.notifier)
                        .dismiss,
                  ),
                ),
              ),
            _box(_filter(filter, wide: layout.columns == 3)),
            if (filter.shows(ThemeGalleryFilter.builtIn)) ...[
              _box(const ThemeGallerySectionHeader(title: 'Built in')),
              _grid(
                layout,
                gallery.builtIn,
                (e) => card(e, Key('theme-builtin-${e.choice!.name}')),
              ),
            ],
            if (filter.shows(ThemeGalleryFilter.mine))
              ..._mine(gallery, layout, menu, enabled, card),
            if (filter.shows(ThemeGalleryFilter.space))
              ..._space(gallery, layout, card),
            _box(SizedBox(height: SettingsSubPages.bottomInsetOf(context))),
          ],
        );
      },
    );
  }

  VoidCallback? _customise(ThemeGalleryEntry entry) {
    if (entry.kind != ThemeGalleryKind.builtIn) return null;
    final seed = customiseSeed(entry.choice!);
    return seed == null ? null : () => _openEditor(seed);
  }

  Widget _box(Widget child) => SliverToBoxAdapter(child: child);

  Widget _filter(ThemeGalleryFilter filter, {required bool wide}) {
    final options = [
      for (final label in _filters.values) AppSegmentedOption(label: label),
    ];
    final index = _filters.keys.toList().indexOf(filter);
    void select(int i) => ref
        .read(themeGalleryFilterProvider.notifier)
        .select(_filters.keys.elementAt(i));
    return Padding(
      padding: EdgeInsets.only(top: wide ? AppSpacing.s8 : 0),
      child: wide
          ? Align(
              alignment: Alignment.centerLeft,
              child: AppSegmentedControl.inline(
                key: const Key('themes-filter'),
                options: options,
                selectedIndex: index,
                onSegmentSelected: select,
                semanticLabel: 'Show themes',
              ),
            )
          : AppSegmentedControl.fill(
              key: const Key('themes-filter'),
              options: options,
              selectedIndex: index,
              onSegmentSelected: select,
              semanticLabel: 'Show themes',
            ),
    );
  }

  Widget _grid(
    ThemeGalleryLayout layout,
    List<ThemeGalleryEntry> entries,
    Widget Function(ThemeGalleryEntry) build,
  ) => SliverGrid.builder(
    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: layout.columns,
      mainAxisSpacing: kThemeGalleryGap,
      crossAxisSpacing: kThemeGalleryGap,
      mainAxisExtent: layout.cardHeight,
    ),
    itemCount: entries.length,
    itemBuilder: (context, i) => build(entries[i]),
  );

  List<Widget> _mine(
    ThemeGallery gallery,
    ThemeGalleryLayout layout,
    ThemeGalleryMenu menu,
    bool enabled,
    _CardBuilder card,
  ) {
    final size = AppTouchTargets.of(context)
        ? AppButtonSize.md
        : AppButtonSize.sm;
    final unsaved = gallery.unsaved;
    return [
      _box(
        ThemeGallerySectionHeader(
          title: 'Mine',
          count: '${gallery.mine.length} of $myThemesMax',
          actions: [
            AppButton(
              key: const Key('theme-import'),
              label: 'Import',
              icon: AppIcons.upload,
              size: size,
              onPressed: () => unawaited(_actions.importFile()),
            ),
            AppButton(
              key: const Key('theme-new'),
              label: 'New',
              icon: AppIcons.add,
              size: size,
              onPressed: () {
                if (enabled) _openEditor(null);
              },
            ),
          ],
        ),
      ),
      if (unsaved != null)
        _box(
          Padding(
            padding: EdgeInsets.only(
              bottom: gallery.mine.isEmpty ? 0 : kThemeGalleryGap,
            ),
            child: ThemeGalleryUnsavedCard(
              key: const Key('theme-mine'),
              entry: unsaved,
              miniatureWidth: layout.cardWidth,
              wide: layout.columns == 3,
              enabled: enabled,
              onSave: () => unawaited(_actions.saveToMine(unsaved.document!)),
              menuItems: menu.itemsFor(unsaved)!,
              sheetHeader: (_) => menu.sheetHeader(unsaved),
            ),
          ),
        ),
      if (gallery.mine.isEmpty && unsaved == null)
        _box(
          const ThemeGalleryEmptyTile(
            key: Key('theme-mine-empty'),
            title: 'No themes of your own yet.',
            next: 'Use New, or the pencil on a built-in theme.',
          ),
        )
      else
        _grid(
          layout,
          gallery.mine,
          (e) => card(
            e,
            Key('theme-mine-${e.id}'),
            menuKey: Key('theme-mine-${e.id}-menu'),
          ),
        ),
    ];
  }

  List<Widget> _space(
    ThemeGallery gallery,
    ThemeGalleryLayout layout,
    _CardBuilder card,
  ) => [
    _box(
      const ThemeGallerySectionHeader(
        title: 'Space',
        count: 'Shared by members',
      ),
    ),
    switch (gallery.spaceState) {
      ThemeGallerySpaceState.failed => _box(
        AppErrorState(
          key: const Key('themes-store-error'),
          message: 'Could not load the Space themes.',
          onRetry: () => ref.invalidate(spaceThemesProvider),
        ),
      ),
      ThemeGallerySpaceState.loading => _box(
        const Padding(
          padding: EdgeInsets.all(AppSpacing.s16),
          child: Center(child: AppSpinner()),
        ),
      ),
      ThemeGallerySpaceState.loaded when gallery.space.isEmpty => _box(
        const ThemeGalleryEmptyTile(
          key: Key('theme-store-empty'),
          title: 'No shared themes yet.',
          next: 'Publish one from Mine to share it here.',
        ),
      ),
      ThemeGallerySpaceState.loaded => _grid(
        layout,
        gallery.space,
        (e) => card(
          e,
          Key('theme-store-${e.id}'),
          menuKey: Key('theme-menu-${e.id}'),
        ),
      ),
    },
  ];
}
