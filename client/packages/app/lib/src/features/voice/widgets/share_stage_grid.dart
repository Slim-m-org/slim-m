// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Screen-share tiles when a call has more than one watched share: the grid
/// that shows them together, and the thumbnail a focused call keeps of the rest.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import 'focusable_video_press.dart';
import 'fullscreen_video_overlay.dart';
import 'screen_share_stage.dart';
import 'share_stage_controls.dart';
import 'stream_quality_chip.dart';
import 'stream_quality_row.dart';
import 'stream_volume_pill.dart';
import 'video_label_pill.dart';

const double _shareAspect = 16 / 9;
const double _gap = AppSpacing.s12;

/// The gap and one caption line under each tile.
const double shareGridCaptionHeight = AppSpacing.s4 + 20;

/// The columns, and the tile width, that give [count] shares the largest 16:9
/// tiles that fit [pane]; an unbounded height leaves the width to decide.
({int columns, double tileWidth}) shareGridFit(Size pane, int count) {
  var best = (columns: 1, tileWidth: 0.0);
  for (var columns = 1; columns <= count; columns++) {
    final rows = (count / columns).ceil();
    final byWidth = (pane.width - (columns - 1) * _gap) / columns;
    final rowHeight =
        (pane.height - (rows - 1) * _gap) / rows - shareGridCaptionHeight;
    final byHeight = pane.height.isFinite
        ? rowHeight * _shareAspect
        : double.infinity;
    final width = (byWidth < byHeight ? byWidth : byHeight).floorToDouble();
    // Within a few percent, one even row reads tidier than a ragged extra one.
    if (width >= best.tileWidth * 0.95) {
      best = (columns: columns, tileWidth: width);
    }
  }
  if (best.tileWidth >= shareGridMinTile) return best;
  return _scrollingFit(pane.width, count);
}

/// The narrowest tile worth fitting the height for; below it the grid scrolls.
const double shareGridMinTile = 240;

/// As many columns as keep each tile at [shareGridMinTile], letting the rows run past the pane.
({int columns, double tileWidth}) _scrollingFit(double paneWidth, int count) {
  var columns = 1;
  while (columns < count &&
      (paneWidth - columns * _gap) / (columns + 1) >= shareGridMinTile) {
    columns++;
  }
  final width = (paneWidth - (columns - 1) * _gap) / columns;
  return (columns: columns, tileWidth: width.floorToDouble());
}

/// The strip's inline volume for [sharer]'s share.
Widget shareStripVolume(
  VoiceParticipant sharer,
  VoiceController controller,
  ValueChanged<bool> hold,
) => StreamVolumePill(
  identity: sharer.identity,
  controller: controller,
  onHold: hold,
);

/// The strip's live quality chip for [sharer]'s share.
Widget shareStripQuality(
  VoiceParticipant sharer,
  VoiceController controller,
  ValueChanged<bool> hold,
) => StreamQualityChip(
  sampler: controller.callStats,
  identity: sharer.identity,
  onHold: hold,
);

/// One share's stage tile, with the opt-out and focus controls bound to it.
Widget shareStageTile(
  BuildContext context,
  VoiceParticipant sharer,
  VoiceController controller, {
  VoidCallback? onStopWatching,
  VoidCallback? onFocus,
  bool focused = false,
  bool showCaption = true,
}) {
  return _stageTile(
    context,
    sharer,
    controller,
    onStopWatching: onStopWatching,
    onFocus: onFocus,
    focused: focused,
    showCaption: showCaption,
  );
}

Widget _stageTile(
  BuildContext context,
  VoiceParticipant sharer,
  VoiceController controller, {
  VoidCallback? onStopWatching,
  VoidCallback? onFocus,
  bool focused = false,
  bool showCaption = true,
}) => ScreenShareStage(
  sharerName: sharer.name,
  isLocal: sharer.isLocal,
  popOutIdentity: sharer.identity,
  annotateSharerId: sharer.isLocal ? null : sharer.identity,
  previewMarksOf: sharer.isLocal ? sharer.identity : null,
  onStopWatching: onStopWatching,
  onFocus: onFocus,
  focused: focused,
  showCaption: showCaption,
  streamVolume:
      !sharer.isLocal && controller.volumes.hasScreenAudio(sharer.identity)
      ? streamVolumeSlider(sharer.identity, controller)
      : null,
  stripVolume:
      !sharer.isLocal && controller.volumes.hasScreenAudio(sharer.identity)
      ? (hold) => shareStripVolume(sharer, controller, hold)
      : null,
  stripQuality: sharer.isLocal
      ? null
      : (hold) => shareStripQuality(sharer, controller, hold),
  quality: sharer.isLocal
      ? null
      : StreamQualityRow(
          sampler: controller.callStats,
          identity: sharer.identity,
          source: CallStatsSource.screenShare,
        ),
  onExpand: () => showFullscreenVideo(
    context,
    identity: sharer.identity,
    label: sharer.isLocal ? 'Your screen' : "${sharer.name}'s screen",
    kind: FullscreenVideoKind.screenShare,
  ),
  child: controller.screenShareViewFor(sharer.identity),
);

String _shareCaption(VoiceParticipant p) =>
    p.isLocal ? 'Your screen' : "${p.name}'s screen";

/// Every watched share at once, each 16:9 with its name underneath, as large
/// as the pane it sits in allows.
class ShareGrid extends StatelessWidget {
  const ShareGrid({
    super.key,
    required this.shares,
    required this.controller,
    required this.onStopWatching,
    required this.onFocus,
    required this.maxHeight,
  });

  final List<VoiceParticipant> shares;
  final VoiceController controller;
  final void Function(String identity) onStopWatching;
  final void Function(String identity) onFocus;

  /// The height the grid may fill before it scrolls.
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = shareGridFit(
          Size(constraints.maxWidth, maxHeight),
          shares.length,
        ).tileWidth;
        return Wrap(
          alignment: WrapAlignment.center,
          spacing: _gap,
          runSpacing: _gap,
          children: [
            for (final share in shares)
              SizedBox(
                key: ValueKey('share-tile-${share.identity}'),
                width: width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AspectRatio(
                      aspectRatio: _shareAspect,
                      child: shareStageTile(
                        context,
                        share,
                        controller,
                        onStopWatching: () => onStopWatching(share.identity),
                        onFocus: () => onFocus(share.identity),
                        showCaption: false,
                      ),
                    ),
                    const SizedBox(height: AppSpacing.s4),
                    Text(
                      _shareCaption(share),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppText.caption.copyWith(
                        color: tokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
      },
    );
  }
}

/// A small live view of an unfocused share; tapping it gives that share the room.
class ShareThumbnail extends StatelessWidget {
  const ShareThumbnail({
    super.key,
    required this.sharer,
    required this.controller,
    required this.height,
    required this.onFocus,
  });

  final VoiceParticipant sharer;
  final VoiceController controller;
  final double height;
  final VoidCallback onFocus;

  /// How wide a thumbnail [height] tall draws.
  static double widthFor(double height) => height * _shareAspect;

  @override
  Widget build(BuildContext context) => FocusableVideoPress(
    semanticLabel: 'Focus ${_shareCaption(sharer)}',
    onPressed: onFocus,
    child: SizedBox(
      width: widthFor(height),
      height: height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.card),
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(
              color: Colors.black,
              child: IgnorePointer(
                child: controller.screenShareViewFor(sharer.identity),
              ),
            ),
            Positioned(
              left: AppSpacing.s8,
              right: AppSpacing.s8,
              bottom: AppSpacing.s4,
              child: Row(
                children: [
                  Flexible(
                    child: VideoLabelPill(
                      child: Text(
                        _shareCaption(sharer),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppText.micro.copyWith(
                          color: Theme.of(
                            context,
                          ).extension<AppTokens>()!.textPrimary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
