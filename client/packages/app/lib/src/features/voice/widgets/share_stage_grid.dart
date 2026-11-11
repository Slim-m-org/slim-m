// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One screen share's stage tile, with the controls bound to its sharer.
library;

import 'package:flutter/material.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import 'fullscreen_video_overlay.dart';
import 'screen_share_stage.dart';
import 'share_stage_controls.dart';
import 'stream_quality_chip.dart';
import 'stream_quality_row.dart';
import 'stream_volume_pill.dart';

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
  // Keyed by sharer so a refocus builds a new stage, which starts at fit.
  key: ValueKey('share-stage-${sharer.identity}'),
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
