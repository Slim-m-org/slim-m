// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One participant's tile as the call stage builds it.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/share_watch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_health.dart';
import 'call_participant_tiles.dart';
import 'fullscreen_video_overlay.dart';

/// One participant's tile, shared by every place the stage lays one out: their live
/// camera when it is on (local participants included, now that there is no
/// separate enlarged self-preview to show it instead), their avatar
/// otherwise, and a way to open either full screen.
Widget participantTile(
  BuildContext context,
  VoiceParticipant participant,
  VoiceController controller,
  void Function(BuildContext anchor, VoiceParticipant participant)
  onOpenProfile, {
  double width = kCallTileMinWidth,
  double? height,
  List<Widget> Function(
    BuildContext,
    VoiceParticipant,
    VoidCallback, {
    bool withStreams,
  })?
  menuItemsBuilder,
}) {
  final showsCamera = participant.isCameraOn;
  return Consumer(
    builder: (_, ref, _) => CallParticipantTile(
      participant: participant.copyWith(
        isSpeaking: ref.watch(
          participantSpeakingProvider(participant.identity),
        ),
      ),
      width: width,
      height: height,
      poorConnection: ref.watch(
        poorConnectionsProvider.select((s) => s.contains(participant.identity)),
      ),
      shareHidden: ref.watch(
        shareWatchProvider.select(
          (w) =>
              w.stopped.contains(participant.identity) &&
              !w.held.contains(participant.identity),
        ),
      ),
      // CallParticipantTile hands back its own context here - see its own doc.
      onTap: (anchor) => onOpenProfile(anchor, participant),
      cameraView: showsCamera
          ? controller.cameraViewFor(participant.identity)
          : null,
      onExpand: showsCamera
          ? () => showFullscreenVideo(
              context,
              identity: participant.identity,
              label: participant.isLocal ? 'Your camera' : participant.name,
              kind: FullscreenVideoKind.camera,
            )
          : null,
      contextMenuItemsBuilder: menuItemsBuilder == null
          ? null
          : (menuContext, close) =>
                menuItemsBuilder(menuContext, participant, close),
    ),
  );
}
