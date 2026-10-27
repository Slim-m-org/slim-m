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
import 'stream_quality_row.dart';

const double _shareAspect = 16 / 9;
const double _gap = AppSpacing.s12;

/// Window widths where the grid gains columns.
const double shareGridTwoColumnsMinWidth = 600;
const double shareGridWideMinWidth = 1000;

/// Columns for [count] shares: stacked on a phone, two on a medium window, and
/// side by side (or 2x2) on a wide one.
int shareGridColumns(double windowWidth, int count) {
  if (windowWidth < shareGridTwoColumnsMinWidth) return 1;
  if (windowWidth < shareGridWideMinWidth) return 2;
  return count == 2 || count == 4 ? 2 : 3;
}

/// One share's stage tile, with the opt-out and focus controls bound to it.
Widget shareStageTile(
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
  onStopWatching: onStopWatching,
  onFocus: onFocus,
  focused: focused,
  showCaption: showCaption,
  streamVolume: !sharer.isLocal && controller.hasScreenAudio(sharer.identity)
      ? streamVolumeSlider(sharer.identity, controller)
      : null,
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

/// Every watched share at once, each 16:9 with its name underneath.
class ShareGrid extends StatelessWidget {
  const ShareGrid({
    super.key,
    required this.shares,
    required this.controller,
    required this.onStopWatching,
    required this.onFocus,
  });

  final List<VoiceParticipant> shares;
  final VoiceController controller;
  final void Function(String identity) onStopWatching;
  final void Function(String identity) onFocus;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final cols = shareGridColumns(
      MediaQuery.sizeOf(context).width,
      shares.length,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = ((constraints.maxWidth - (cols - 1) * _gap) / cols)
            .floorToDouble();
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

  @override
  Widget build(BuildContext context) => FocusableVideoPress(
    semanticLabel: 'Focus ${_shareCaption(sharer)}',
    onPressed: onFocus,
    child: SizedBox(
      width: height * _shareAspect,
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
              child: Text(
                _shareCaption(sharer),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.micro.copyWith(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
