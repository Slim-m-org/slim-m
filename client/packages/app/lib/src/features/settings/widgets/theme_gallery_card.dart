// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One theme in the gallery: a miniature of the app in its own colours, its
/// name and where it came from, and a pencil or a menu. Tap applies it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/providers.dart' show AppThemeChoice;
import '../providers/theme_gallery.dart';
import 'theme_gallery_frame.dart';
import 'theme_gallery_layout.dart';
import 'theme_menu_region.dart';
import 'theme_miniature.dart';
import 'theme_picture.dart';

class ThemeGalleryCard extends ConsumerStatefulWidget {
  const ThemeGalleryCard({
    super.key,
    required this.entry,
    required this.width,
    required this.enabled,
    required this.onApply,
    this.onCustomise,
    this.menuItems,
    this.sheetHeader,
    this.menuKey,
  });

  final ThemeGalleryEntry entry;

  /// The drawn width, which a picture decodes at.
  final double width;

  /// False while an action runs: the card keeps focus but does nothing.
  final bool enabled;
  final VoidCallback onApply;

  /// A built-in's pencil; null shows none.
  final VoidCallback? onCustomise;

  /// The menu right-click, long-press and the kebab open; null shows no kebab.
  final List<Widget> Function(BuildContext context, VoidCallback close)?
  menuItems;
  final WidgetBuilder? sheetHeader;

  /// On the kebab, for a test.
  final Key? menuKey;

  @override
  ConsumerState<ThemeGalleryCard> createState() => _ThemeGalleryCardState();
}

class _ThemeGalleryCardState extends ConsumerState<ThemeGalleryCard> {
  bool _hovered = false;
  bool _focused = false;

  /// Kept across rebuilds while the picture and tokens hold, so applying one
  /// card does not rebuild every miniature on the page.
  Widget? _miniature;
  Object? _miniatureOf;

  ThemeGalleryEntry get _entry => widget.entry;
  bool get _tappable => widget.enabled && _entry.broken == null;

  Widget _top(ImageProvider? picture) {
    final key = (
      _entry.tokens,
      _entry.split,
      _entry.brightness,
      _entry.broken,
      picture,
    );
    if (_miniature != null && _miniatureOf == key) return _miniature!;
    _miniatureOf = key;
    final tokens = _entry.tokens;
    final broken = _entry.broken;
    return _miniature = tokens == null || broken != null
        ? ThemeBrokenPlaceholder(broken: broken ?? ThemeBroken.unreadable)
        : ThemeMiniature(
            tokens: tokens,
            brightness: _entry.brightness,
            split: _entry.split,
            picture: picture,
          );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final card = ThemeCardFrame(
      inUse: _entry.inUse,
      hovered: _hovered && _tappable,
      focused: _focused,
      child: Stack(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _top(
                watchThemePicture(
                  ref,
                  context,
                  id: _entry.pictureId,
                  width: widget.width,
                ),
              ),
              ColoredBox(
                color: tokens.borderSubtle,
                child: const SizedBox(height: 1),
              ),
              Expanded(child: _foot(tokens)),
            ],
          ),
          if (_entry.isSpaceDefault)
            const Positioned(
              left: AppSpacing.s8,
              top: AppSpacing.s8,
              child: _DefaultTag(),
            ),
          if (_entry.inUse)
            const Positioned(
              right: AppSpacing.s8,
              top: AppSpacing.s8,
              child: ThemeInUseBadge(),
            ),
        ],
      ),
    );
    return ThemeMenuRegion(
      items: widget.menuItems,
      enabled: widget.enabled,
      sheetHeader: widget.sheetHeader,
      child: Semantics(
        container: true,
        button: true,
        enabled: _tappable,
        selected: _entry.inUse,
        label: _semantics(_entry),
        child: FocusableActionDetector(
          enabled: _entry.broken == null,
          mouseCursor: _tappable ? SystemMouseCursors.click : MouseCursor.defer,
          onShowHoverHighlight: (v) => setState(() => _hovered = v),
          onShowFocusHighlight: (v) => setState(() => _focused = v),
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _tappable ? widget.onApply() : null,
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _tappable ? widget.onApply : null,
            child: card,
          ),
        ),
      ),
    );
  }

  Widget _foot(AppTokens tokens) {
    final broken = _entry.broken != null;
    return ColoredBox(
      color: _entry.inUse ? tokens.accentSoft : Colors.transparent,
      child: Padding(
        padding: themeCardFootPadding,
        child: Row(
          children: [
            Expanded(
              child: ExcludeSemantics(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _entry.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: themeCardNameStyle.copyWith(
                        color: broken
                            ? tokens.textSecondary
                            : tokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    _Meta(entry: _entry),
                  ],
                ),
              ),
            ),
            ?_trailing(),
          ],
        ),
      ),
    );
  }

  /// Runs [action] unless another is running; the button keeps focus either way.
  VoidCallback _whenIdle(VoidCallback action) => () {
    if (widget.enabled) action();
  };

  Widget? _trailing() {
    final customise = widget.onCustomise;
    if (customise != null) {
      return ThemeCardButton(
        key: Key('theme-customise-${_entry.choice?.name}'),
        icon: AppIcons.edit,
        label: 'Customise ${_entry.name}',
        tooltip: 'Customise',
        onPressed: _whenIdle(customise),
      );
    }
    if (widget.menuItems == null) return null;
    return ThemeMenuKebab(
      key: widget.menuKey,
      label: 'More for ${_entry.name}',
    );
  }
}

/// What a screen reader hears for a card: its name, where it came from, and
/// why it cannot be applied.
String _semantics(ThemeGalleryEntry entry) => [
  entry.name,
  if (entry.isSpaceDefault) 'Space default',
  if (entry.choice == AppThemeChoice.system)
    'follows your device'
  else if (entry.author case final author?)
    'by $author'
  else if (entry.broken == null)
    entry.brightness == Brightness.light ? 'light theme' : 'dark theme',
  if (entry.pictureId != null) 'with a picture',
  ?switch (entry.broken) {
    ThemeBroken.contrast => 'fails a contrast check, cannot be applied',
    ThemeBroken.unreadable => 'cannot be read, cannot be applied',
    null => null,
  },
  if (entry.inUse) 'in use',
].join(', ');

/// The line under a card's name: In use, or the theme's mode and author.
class _Meta extends StatelessWidget {
  const _Meta({required this.entry});

  final ThemeGalleryEntry entry;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final light = entry.brightness == Brightness.light;
    final mode = light ? 'Light' : 'Dark';
    final (icons, text) = entry.inUse
        ? ([AppIcons.check], 'In use')
        : entry.choice == AppThemeChoice.system
        ? ([AppIcons.deviceDesktop], 'Follows your device')
        : entry.broken != null
        ? (
            const <IconData>[],
            entry.author == null ? 'Space' : 'By ${entry.author}',
          )
        : (
            [
              light ? AppIcons.themeLight : AppIcons.themeDark,
              if (entry.pictureId != null) AppIcons.image,
            ],
            entry.author == null ? mode : 'By ${entry.author}',
          );
    final colour = entry.inUse ? tokens.accent : tokens.textSecondary;
    return Row(
      spacing: AppSpacing.s4,
      children: [
        for (final icon in icons)
          Icon(icon, size: AppSizes.icon12, color: colour),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppText.caption.copyWith(color: colour),
          ),
        ),
      ],
    );
  }
}

/// The Space default tag, on the miniature so it never narrows the name.
class _DefaultTag extends StatelessWidget {
  const _DefaultTag();

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ExcludeSemantics(
      child: DecoratedBox(
        key: const Key('theme-store-default-badge'),
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: BorderRadius.circular(AppRadii.control),
        ),
        child: const AppBadge(
          variant: AppBadgeVariant.tag,
          label: 'Space default',
          markerIcon: AppIcons.pin,
        ),
      ),
    );
  }
}
