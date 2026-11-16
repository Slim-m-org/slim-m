// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Recent row on Appearance's Theme card: the theme in use, marked, then
/// the last few applied, each one tap from being applied again. With a
/// pointer, resting on a tile previews it in the card's hero.
library;

import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/theme_gallery.dart';
import '../providers/theme_store.dart';
import 'theme_miniature.dart';

/// The theme the hero shows instead of the one in use: the tile a pointer
/// rests on or the keyboard is on.
class RecentThemePreview extends ValueNotifier<ThemeGalleryEntry?> {
  RecentThemePreview() : super(null);

  bool _held = false;

  void enter(ThemeGalleryEntry entry) {
    if (!_held) _show(entry);
  }

  void move(ThemeGalleryEntry entry) {
    _held = false;
    _show(entry);
  }

  void leave(ThemeGalleryEntry entry) {
    if (value?.source == entry.source) value = null;
  }

  /// A click reorders the row under a still pointer, so nothing previews
  /// again until the pointer moves.
  void applied() {
    _held = true;
    value = null;
  }

  void _show(ThemeGalleryEntry entry) {
    final next = entry.inUse ? null : entry;
    if (next?.source != value?.source) value = next;
  }
}

class AppearanceRecentRow extends StatelessWidget {
  const AppearanceRecentRow({
    super.key,
    required this.tiles,
    required this.columns,
    required this.enabled,
    required this.onApply,
    required this.preview,
  });

  /// The theme in use first.
  final List<ThemeGalleryEntry> tiles;
  final int columns;

  /// False while an action runs.
  final bool enabled;
  final ValueChanged<ThemeGalleryEntry> onApply;
  final RecentThemePreview preview;

  static const gap = AppSpacing.s12;

  static Key tileKey(ThemeGalleryEntry entry) =>
      Key('recent-theme-${entry.source.key}');

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.s16,
        AppSpacing.s12,
        AppSpacing.s16,
        AppSpacing.s16,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        spacing: AppSpacing.s8,
        children: [
          Text(
            'RECENT',
            semanticsLabel: 'Recent',
            style: AppText.label.copyWith(color: tokens.textSecondary),
          ),
          LayoutBuilder(
            builder: (context, box) {
              final width = (box.maxWidth - gap * (columns - 1)) / columns;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: gap,
                children: [
                  for (final entry in tiles.take(columns))
                    SizedBox(
                      width: width,
                      child: _RecentTile(
                        key: tileKey(entry),
                        entry: entry,
                        width: width,
                        enabled: enabled,
                        onApply: onApply,
                        preview: preview,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _RecentTile extends ConsumerStatefulWidget {
  const _RecentTile({
    super.key,
    required this.entry,
    required this.width,
    required this.enabled,
    required this.onApply,
    required this.preview,
  });

  final ThemeGalleryEntry entry;
  final double width;
  final bool enabled;
  final ValueChanged<ThemeGalleryEntry> onApply;
  final RecentThemePreview preview;

  @override
  ConsumerState<_RecentTile> createState() => _RecentTileState();
}

class _RecentTileState extends ConsumerState<_RecentTile> {
  bool _focused = false;

  ThemeGalleryEntry get _entry => widget.entry;
  bool get _tappable => widget.enabled && !_entry.inUse;

  void _apply() {
    widget.preview.applied();
    widget.onApply(_entry);
  }

  void _focus(bool focused) {
    setState(() => _focused = focused);
    focused ? widget.preview.move(_entry) : widget.preview.leave(_entry);
  }

  ImageProvider? _picture() {
    final id = _entry.pictureId;
    if (id == null) return null;
    final Uint8List? bytes = ref
        .watch(spaceThemePictureProvider(id))
        .valueOrNull;
    if (bytes == null) return null;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ResizeImage(
      MemoryImage(bytes),
      width: (widget.width * dpr).round(),
      policy: ResizeImagePolicy.fit,
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final current = _entry.inUse;
    final radius = BorderRadius.circular(AppRadii.control);
    final miniature = DecoratedBox(
      position: DecorationPosition.foreground,
      decoration: BoxDecoration(
        border: Border.all(color: tokens.borderSubtle),
        borderRadius: radius,
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: ThemeMiniature(
          tokens: _entry.tokens!,
          brightness: _entry.brightness,
          split: _entry.split,
          picture: _picture(),
        ),
      ),
    );
    final ring = _focused
        ? tokens.focusRing
        : (current ? tokens.accentFill : null);
    final tile = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      spacing: AppSpacing.s8,
      children: [
        Stack(
          clipBehavior: Clip.none,
          children: [
            miniature,
            if (ring != null)
              Positioned(
                left: -3,
                top: -3,
                right: -3,
                bottom: -3,
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      border: Border.all(color: ring, width: 2),
                      borderRadius: BorderRadius.circular(AppRadii.control + 3),
                    ),
                  ),
                ),
              ),
          ],
        ),
        Text(
          _entry.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppText.caption.copyWith(
            color: current ? tokens.textPrimary : tokens.textSecondary,
            fontWeight: current ? AppWeights.medium : null,
          ),
        ),
      ],
    );
    return Semantics(
      container: true,
      button: true,
      enabled: _tappable,
      selected: current,
      label: current ? '${_entry.name}, in use' : _entry.name,
      child: MouseRegion(
        onEnter: (_) => widget.preview.enter(_entry),
        onHover: (_) => widget.preview.move(_entry),
        onExit: (_) => widget.preview.leave(_entry),
        child: FocusableActionDetector(
          enabled: widget.enabled,
          mouseCursor: _tappable ? SystemMouseCursors.click : MouseCursor.defer,
          onShowFocusHighlight: _focus,
          actions: {
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) => _tappable ? _apply() : null,
            ),
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _tappable ? _apply : null,
            child: ExcludeSemantics(child: tile),
          ),
        ),
      ),
    );
  }
}
