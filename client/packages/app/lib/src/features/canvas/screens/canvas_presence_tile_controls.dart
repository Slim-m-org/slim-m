// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two small presentational pieces `canvas_presence_tile.dart` paints
/// over a tile's own content - split out to keep that file, which also
/// carries the tile's gesture handling, under the review budget.
///
/// Neither carries a background plate any more - report 3 in the backlog
/// channel asked for the permanent translucent bubble behind them gone,
/// alongside `canvas_presence_tile.dart`'s own reveal-on-hover/press gate
/// that already keeps both off screen until asked for. Each `AppIconButton`
/// still paints its own hover fill, the same affordance every other icon
/// button in this design system already has.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The corner handle a tile's own resize drag starts from.
///
/// Grows its hit area to [AppSizes.rowTouch] at touch widths and paints the
/// same hover fill and press scale as [AppIconButton], so it reads as one of
/// the tile's controls rather than a bare glyph.
class TileResizeGrip extends StatefulWidget {
  const TileResizeGrip({
    super.key,
    required this.onUpdate,
    required this.onEnd,
  });

  final GestureDragUpdateCallback onUpdate;
  final GestureDragEndCallback onEnd;

  @override
  State<TileResizeGrip> createState() => _TileResizeGripState();
}

class _TileResizeGripState extends State<TileResizeGrip> {
  bool _hovered = false;
  bool _pressed = false;

  void _setPressed(bool value) {
    if (_pressed != value) setState(() => _pressed = value);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final hitTarget = AppTouchTargets.of(context)
        ? AppSizes.rowTouch
        : AppSizes.controlSm;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeUpLeftDownRight,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanDown: (_) => _setPressed(true),
        onPanCancel: () => _setPressed(false),
        onPanUpdate: widget.onUpdate,
        onPanEnd: (details) {
          _setPressed(false);
          widget.onEnd(details);
        },
        child: SizedBox(
          width: hitTarget,
          height: hitTarget,
          child: Align(
            alignment: Alignment.bottomRight,
            child: AnimatedScale(
              scale: _pressed ? AppMotion.pressScale : 1,
              duration: AppMotion.reduced(context, AppMotion.fast),
              curve: AppMotion.entrance,
              child: AnimatedContainer(
                duration: AppMotion.reduced(context, AppMotion.fast),
                curve: AppMotion.entrance,
                width: AppSizes.controlSm,
                height: AppSizes.controlSm,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: _hovered || _pressed
                      ? tokens.surfaceRaised
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Icon(
                  AppIcons.tileResize,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                  shadows: [Shadow(color: tokens.surfaceBase, blurRadius: 4)],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A tile's own expand, lock, depth and hide buttons, pinned to its
/// top-right corner regardless of whether the tile's content currently
/// paints in front of or behind [CanvasSurface].
///
/// [onToggleLocked] and [onToggleSentToBack] follow [onExpand]'s own
/// null-means-no-button shape: an avatar-only tile has no video for a
/// drawing tool to reach through or paint over, so `canvas_presence_layer
/// .dart` passes null for both rather than a button wired to a verb that
/// does nothing useful.
class TileControls extends StatelessWidget {
  const TileControls({
    super.key,
    required this.locked,
    required this.sentToBack,
    this.onToggleLocked,
    this.onToggleSentToBack,
    required this.onHide,
    this.onExpand,
  });

  final bool locked;
  final bool sentToBack;
  final VoidCallback? onToggleLocked;
  final VoidCallback? onToggleSentToBack;
  final VoidCallback onHide;

  /// Opens this tile's own live feed full screen. Null - and so no button at
  /// all, rather than a disabled one - whenever there is no live feed to
  /// open: a camera tile showing the avatar fallback has nothing to fill a
  /// screen with, and `FullscreenVideoView` would pop itself the moment it
  /// opened, the same "no handler rather than a control that cannot work"
  /// treatment `AppSegmentedOption.disabled` already established.
  final VoidCallback? onExpand;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return IconTheme.merge(
      data: IconThemeData(
        shadows: [Shadow(color: tokens.surfaceBase, blurRadius: 4)],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (onExpand case final onExpand?)
            AppIconButton(
              icon: AppIcons.expand,
              semanticLabel: 'Show this tile full screen',
              tooltip: 'Full screen',
              size: AppIconButtonSize.sm,
              onPressed: onExpand,
            ),
          if (onToggleLocked case final onToggleLocked?)
            AppIconButton(
              icon: locked ? AppIcons.tileLocked : AppIcons.tileUnlocked,
              semanticLabel: locked
                  ? 'Unlock this tile'
                  : 'Lock this tile in place',
              tooltip: locked
                  ? 'Unlock - drag and resize again'
                  : 'Lock in place - a drawing tool reaches through it',
              size: AppIconButtonSize.sm,
              active: locked,
              onPressed: onToggleLocked,
            ),
          // The object menu's own "Bring to front"/"Send to back", reached here since a tile absorbs its own right-click - see `canvas_presence_tile.dart`'s own library doc.
          if (onToggleSentToBack case final onToggleSentToBack?)
            AppIconButton(
              icon: sentToBack ? AppIcons.sendToBack : AppIcons.bringToFront,
              semanticLabel: sentToBack
                  ? 'Bring this tile to the front'
                  : 'Send this tile to the back',
              tooltip: sentToBack
                  ? 'Bring to front - back above the ink'
                  : 'Send to back - draw over it',
              size: AppIconButtonSize.sm,
              active: sentToBack,
              onPressed: onToggleSentToBack,
            ),
          AppIconButton(
            icon: AppIcons.tileHide,
            semanticLabel:
                'Hide this tile on your canvas; other participants still see it',
            tooltip: 'Hide on your canvas - others still see it',
            size: AppIconButtonSize.sm,
            onPressed: onHide,
          ),
        ],
      ),
    );
  }
}
