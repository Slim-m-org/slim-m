// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme in use when nothing keeps it: applied from a file, or from a
/// Mine or Space entry that is gone. First in Mine, across the whole grid,
/// with Save to Mine on the card.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/context_menu_region.dart';
import '../providers/theme_gallery.dart';
import '../providers/theme_source.dart';
import 'theme_gallery_frame.dart';
import 'theme_miniature.dart';

/// Why the theme in use is not kept anywhere.
String themeUnsavedLine(ThemeGalleryEntry entry) => switch (entry.lost) {
  SpaceThemeSource() => 'It is no longer in the Space.',
  MineThemeSource() => 'It is no longer in Mine.',
  _ => 'Applied from a file. Save it to keep it.',
};

class ThemeGalleryUnsavedCard extends StatefulWidget {
  const ThemeGalleryUnsavedCard({
    super.key,
    required this.entry,
    required this.miniatureWidth,
    required this.wide,
    required this.enabled,
    required this.onSave,
    required this.menuItems,
    required this.sheetHeader,
  });

  final ThemeGalleryEntry entry;

  /// One grid column, so the miniature matches the cards below it.
  final double miniatureWidth;

  /// Three columns across: Save to Mine sits beside the miniature, not under it.
  final bool wide;
  final bool enabled;
  final VoidCallback onSave;
  final List<Widget> Function(BuildContext context, VoidCallback close)
  menuItems;
  final WidgetBuilder sheetHeader;

  static const menuKey = Key('theme-mine-menu');
  static const saveKey = Key('theme-mine-save');

  @override
  State<ThemeGalleryUnsavedCard> createState() =>
      _ThemeGalleryUnsavedCardState();
}

class _ThemeGalleryUnsavedCardState extends State<ThemeGalleryUnsavedCard> {
  final _region = GlobalKey<ContextMenuRegionState>();

  ThemeGalleryEntry get _entry => widget.entry;

  void _openMenu(BuildContext kebab) {
    final box = kebab.findRenderObject() as RenderBox?;
    _region.currentState?.open(
      at: box?.localToGlobal(Offset(0, box.size.height)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final narrow = !widget.wide;
    final save = AppButton(
      key: ThemeGalleryUnsavedCard.saveKey,
      label: 'Save to Mine',
      icon: AppIcons.check,
      size: AppButtonSize.sm,
      full: narrow,
      disabled: !widget.enabled,
      onPressed: widget.onSave,
    );
    final soft = _entry.inUse ? tokens.accentSoft : Colors.transparent;
    return ContextMenuRegion(
      key: _region,
      ownsFocusNode: false,
      menuWidth: 250,
      itemsBuilder: (context, close) =>
          widget.enabled ? widget.menuItems(context, close) : const [],
      sheetHeaderBuilder: widget.sheetHeader,
      child: Semantics(
        container: true,
        selected: _entry.inUse,
        label: [
          _entry.name,
          'not saved',
          themeUnsavedLine(_entry),
          if (_entry.inUse) 'in use',
        ].join(', '),
        child: ThemeCardFrame(
          inUse: _entry.inUse,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _miniature(),
                    ColoredBox(
                      color: tokens.borderSubtle,
                      child: const SizedBox(width: 1),
                    ),
                    Expanded(
                      child: ColoredBox(
                        color: soft,
                        child: _text(tokens, narrow ? null : save),
                      ),
                    ),
                  ],
                ),
              ),
              if (narrow)
                ColoredBox(
                  color: soft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.s12,
                      0,
                      AppSpacing.s12,
                      AppSpacing.s12,
                    ),
                    child: save,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _miniature() {
    final tokens = _entry.tokens;
    return SizedBox(
      width: widget.miniatureWidth,
      child: Align(
        alignment: Alignment.topCenter,
        child: Stack(
          children: [
            if (tokens != null)
              ThemeMiniature(tokens: tokens, brightness: _entry.brightness),
            if (_entry.inUse)
              const Positioned(
                right: AppSpacing.s8,
                top: AppSpacing.s8,
                child: ThemeInUseBadge(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _text(AppTokens tokens, Widget? save) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.s12,
      AppSpacing.s8,
      AppSpacing.s8,
      AppSpacing.s12,
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Text(
                  _entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppText.ui.copyWith(
                    color: tokens.textPrimary,
                    fontWeight: AppWeights.medium,
                  ),
                ),
              ),
            ),
            if (save != null) ...[save, const SizedBox(width: AppSpacing.s4)],
            Builder(
              builder: (kebab) => ThemeCardButton(
                key: ThemeGalleryUnsavedCard.menuKey,
                icon: AppIcons.moreVertical,
                label: 'More for ${_entry.name}',
                tooltip: 'More',
                onPressed: widget.enabled ? () => _openMenu(kebab) : null,
              ),
            ),
          ],
        ),
        const ExcludeSemantics(
          child: AppBadge(variant: AppBadgeVariant.warn, label: 'Not saved'),
        ),
        const SizedBox(height: AppSpacing.s8),
        ExcludeSemantics(
          child: Text(
            themeUnsavedLine(_entry),
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ),
      ],
    ),
  );
}
