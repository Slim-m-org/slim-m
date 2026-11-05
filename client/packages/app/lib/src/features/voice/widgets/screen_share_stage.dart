// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stage a peer's shared screen renders on during a call.
///
/// Its own file rather than more of `voice_screen.dart`, which was over the
/// review budget before this existed. The video itself comes through
/// `VoiceController.screenShareViewFor`, so this file stays free of LiveKit
/// types like everything else outside the rtc package.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../providers/call_mini_player.dart';
import '../../../widgets/double_click_detector.dart';
import '../../messages/widgets/media_label.dart';
import '../providers/popout_window.dart';
import 'share_stage_controls.dart';
import 'stream_control_strip.dart';
import 'stream_controls_reveal.dart';
import '../../../widgets/context_menu_region.dart';
import '../../canvas/widgets/local_share_marks.dart';
import '../../canvas/widgets/screen_annotate_layer.dart';
import '../providers/share_zoom_controller.dart';
import 'share_zoom_view.dart';

/// A dark stage with the share inside it, labelled on hover.
///
/// Black behind the video on purpose, in both themes: a shared screen is
/// arbitrary content, and any chrome tone bleeding around its letterbox reads
/// as part of the screen. The label says whose screen it is, because two
/// people can share in turn and a bare rectangle does not say which.
///
/// That label used to sit in the layout flow underneath the stage, which put
/// it outside the rounded container and left it permanently on. It is now a
/// [MediaLabelChip] inside the clip, revealed by [PointerRevealed] on the same
/// terms as the canvas tile's own - hiding it in place instead would reflow
/// the video every time a pointer crossed it.
///
/// A control strip (volume, live quality, full screen, the menu) shows on
/// hover, on keyboard focus, or for a few seconds after a touch; see
/// [StreamControlStrip]. The same actions stay in the context menu, which a
/// long press opens on touch.
///
/// The local caption reads as a full sentence ("You are sharing your
/// screen") rather than a bare label ("Your screen"): it is what is left to
/// confirm a live share once `local_screen_share_banner.dart`'s own banner
/// is withheld here to avoid saying the identical thing twice.
class ScreenShareStage extends ConsumerStatefulWidget {
  const ScreenShareStage({
    super.key,
    required this.sharerName,
    required this.child,
    this.isLocal = false,
    this.onExpand,
    this.popOutIdentity,
    this.annotateSharerId,
    this.previewMarksOf,
    this.onStopWatching,
    this.onFocus,
    this.focused = false,
    this.showCaption = true,
    this.streamVolume,
    this.quality,
    this.stripVolume,
    this.stripQuality,
  });

  /// The strip's inline volume pill, called with the strip's hold callback; null when the share carries no sound.
  final Widget Function(ValueChanged<bool> hold)? stripVolume;

  /// The strip's live quality chip, called with the strip's hold callback; null for a local share.
  final Widget Function(ValueChanged<bool> hold)? stripQuality;

  /// Off where a caption under the tile already names the sharer, as in the share grid.
  final bool showCaption;

  /// Opens this share's own volume, anchored to the given context; null when it carries no sound.
  final Widget? streamVolume;
  final Widget? quality;

  /// Stops watching this share; null where the tile is not a choosable share.
  final VoidCallback? onStopWatching;

  /// Gives this share the room, or returns to the grid when [focused]; null with one share.
  final VoidCallback? onFocus;
  final bool focused;

  final String sharerName;

  /// Whether this is the local caller's own share, so the caption reads
  /// "Your screen" rather than the caller's own name reflected back.
  final bool isLocal;

  /// The live share view, from `VoiceController.screenShareViewFor`.
  final Widget child;

  /// Opens this share full screen, on a double click or from the menu. Null
  /// only in the tests that build this widget in isolation.
  final VoidCallback? onExpand;

  /// The remote sharer's identity, which offers the pop-out row; null for
  /// the local share, which is never previewed back to the sharer.
  final String? popOutIdentity;

  /// The remote sharer whose screen a viewer may draw on, when they allow it; null for the local share.
  final String? annotateSharerId;

  /// The local sharer, whose own preview shows the marks viewers draw while they may; null for a remote share.
  final String? previewMarksOf;

  @override
  ConsumerState<ScreenShareStage> createState() => _ScreenShareStageState();
}

class _ScreenShareStageState extends ConsumerState<ScreenShareStage> {
  final _menu = GlobalKey<ContextMenuRegionState>();
  final _menuGroup = Object();
  final _zoom = ShareZoomController();

  @override
  void dispose() {
    _zoom.dispose();
    super.dispose();
  }

  void _toggleMenu(BuildContext button) {
    final box = button.findRenderObject() as RenderBox?;
    final at = box?.localToGlobal(Offset(0, box.size.height));
    _menu.currentState?.toggle(at: at);
  }

  void _doubleClick() {
    if (_zoom.zoomed) return _zoom.reset();
    widget.onExpand?.call();
  }

  Widget _preview(String sharerId) => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, box) => Stack(
        clipBehavior: Clip.none,
        children: [
          LocalShareMarks(
            key: const ValueKey('stage-preview-marks'),
            sharerId: sharerId,
            sharerName: widget.sharerName,
            tileRect: Offset.zero & box.biggest,
            zoom: _zoom,
          ),
        ],
      ),
    ),
  );

  Widget _annotate() => Positioned.fill(
    child: LayoutBuilder(
      builder: (context, box) => Stack(
        clipBehavior: Clip.none,
        children: [
          ScreenAnnotateLayer(
            key: const ValueKey('stage-annotate'),
            sharerId: widget.annotateSharerId!,
            sharerName: widget.sharerName,
            tileRect: Offset.zero & box.biggest,
            zoom: _zoom,
          ),
        ],
      ),
    ),
  );

  Widget _video(BuildContext context, AppTokens tokens) {
    return DoubleClickDetector(
      onDoubleClick: _doubleClick,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: PointerRevealed(
          builder: (context, revealed) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: const Color(0xFF000000),
                    border: Border.all(color: tokens.borderSubtle),
                    borderRadius: BorderRadius.circular(AppRadii.card),
                  ),
                  child: ShareZoomView(zoom: _zoom, child: widget.child),
                ),
              ),
              if (widget.annotateSharerId != null) _annotate(),
              if (widget.previewMarksOf != null)
                _preview(widget.previewMarksOf!),
              if (widget.showCaption)
                Positioned(
                  left: 6,
                  bottom: 6,
                  right: 6,
                  child: Align(
                    alignment: Alignment.bottomLeft,
                    child: RevealFade(
                      revealed: revealed || widget.isLocal,
                      child: MediaLabelChip(
                        icon: AppIcons.screenShare,
                        label: widget.isLocal
                            ? 'You are sharing your screen'
                            : "${widget.sharerName}'s screen",
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final popOutId = widget.popOutIdentity;
    final canPopOut =
        popOutId != null &&
        !widget.isLocal &&
        ref.watch(popOutSupportedProvider);
    return StreamControlsReveal(
      builder: (context, shown, hold) => ContextMenuRegion(
        key: _menu,
        tapRegionGroupId: _menuGroup,
        onOpenChanged: hold,
        itemsBuilder: (_, close) => shareStageMenuItems(
          close,
          ShareStageMenu(
            sharerName: widget.sharerName,
            onPopOut: canPopOut
                ? () => ref.read(popOutFeedProvider.notifier).state = (
                    identity: popOutId,
                    name: widget.sharerName,
                    kind: FeedKind.screenShare,
                  )
                : null,
            streamVolume: widget.streamVolume,
            quality: widget.quality,
            onFocus: widget.onFocus,
            focused: widget.focused,
            onStopWatching: widget.onStopWatching,
            onFullscreen: widget.onExpand,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            _video(context, tokens),
            Positioned(
              top: AppSpacing.s8,
              left: AppSpacing.s8,
              right: AppSpacing.s8,
              child: StreamControlStrip(
                shown: shown,
                menuGroup: _menuGroup,
                onMore: _toggleMenu,
                onFullscreen: widget.onExpand,
                volume: widget.stripVolume?.call(hold),
                quality: widget.stripQuality?.call(hold),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
