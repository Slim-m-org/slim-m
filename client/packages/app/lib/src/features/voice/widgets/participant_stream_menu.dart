// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stream rows on a participant's context menu: the same verbs the share
/// tile's own menu offers, for whoever is sharing or has a camera on.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/call_mini_player.dart';
import '../providers/popout_window.dart';
import '../providers/share_watch.dart';
import '../providers/voice_controller.dart';
import '../providers/voice_flags.dart' show voiceParticipantsProvider;
import 'fullscreen_video_overlay.dart';
import 'share_stage_controls.dart';

/// Rows for [identity]'s live streams in the joined call; empty when they are
/// not publishing one there, which is also every rail row of another channel.
List<Widget> participantStreamMenuItems(
  BuildContext context,
  WidgetRef ref, {
  required String identity,
  required VoidCallback close,
  bool withFullscreen = true,
  bool autofocusStreamVolume = true,
}) {
  final live = ref
      .read(voiceParticipantsProvider)
      .where((p) => p.identity == identity)
      .firstOrNull;
  if (live == null) return const [];
  return [
    if (live.isScreenSharing)
      ..._screenRows(
        context,
        ref,
        live,
        close,
        withFullscreen,
        autofocusStreamVolume,
      ),
    ..._cameraRows(context, ref, live, close, withFullscreen),
  ];
}

VoidCallback? _popOut(WidgetRef ref, VoiceParticipant p, FeedKind kind) {
  if (p.isLocal || !ref.read(popOutSupportedProvider)) return null;
  return () => ref.read(popOutFeedProvider.notifier).state = (
    identity: p.identity,
    name: p.name,
    kind: kind,
  );
}

List<Widget> _screenRows(
  BuildContext context,
  WidgetRef ref,
  VoiceParticipant p,
  VoidCallback close,
  bool withFullscreen,
  bool autofocusVolume,
) {
  final watch = ref.read(shareWatchProvider.notifier);
  if (ref.read(shareWatchProvider).stopped.contains(p.identity)) {
    return [
      AppMenuItem(
        label: 'Show stream',
        leading: AppIcons.preview,
        onTap: () {
          close();
          watch.watch(p.identity);
        },
      ),
    ];
  }
  final controller = ref.read(voiceControllerProvider.notifier);
  return shareStageMenuItems(
    close,
    ShareStageMenu(
      sharerName: p.name,
      onPopOut: _popOut(ref, p, FeedKind.screenShare),
      streamVolume: !p.isLocal && controller.hasScreenAudio(p.identity)
          ? streamVolumeSlider(
              p.identity,
              controller,
              autofocus: autofocusVolume,
            )
          : null,
      onStopWatching: () => watch.stop(p.identity),
      onFullscreen: withFullscreen
          ? () => showFullscreenVideo(
              context,
              identity: p.identity,
              label: p.isLocal ? 'Your screen' : "${p.name}'s screen",
              kind: FullscreenVideoKind.screenShare,
            )
          : null,
    ),
  );
}

List<Widget> _cameraRows(
  BuildContext context,
  WidgetRef ref,
  VoiceParticipant p,
  VoidCallback close,
  bool withFullscreen,
) {
  final controller = ref.read(voiceControllerProvider.notifier);
  if (!p.isLocal && controller.isCameraHidden(p.identity)) {
    return [
      AppMenuItem(
        label: 'Show camera',
        leading: AppIcons.camera,
        onTap: () {
          close();
          unawaited(controller.setCameraHidden(p.identity, false));
        },
      ),
    ];
  }
  if (!p.isCameraOn) return const [];
  final popOut = _popOut(ref, p, FeedKind.camera);
  return [
    if (popOut != null)
      AppMenuItem(
        label: 'Pop out camera',
        leading: AppIcons.popOut,
        onTap: () {
          close();
          popOut();
        },
      ),
    if (!p.isLocal)
      AppMenuItem(
        label: 'Hide camera',
        leading: AppIcons.tileHide,
        onTap: () {
          close();
          unawaited(controller.setCameraHidden(p.identity, true));
        },
      ),
    if (withFullscreen)
      AppMenuItem(
        label: 'Camera full screen',
        leading: AppIcons.expand,
        onTap: () {
          close();
          showFullscreenVideo(
            context,
            identity: p.identity,
            label: p.isLocal ? 'Your camera' : p.name,
            kind: FullscreenVideoKind.camera,
          );
        },
      ),
  ];
}
