// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small label over a remote video tile when its picture is not live:
/// paused by the server, stalled while recovery runs, or stopped. Nothing at
/// all while the video plays, so a healthy tile is untouched.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'local_preview_gate.dart';
import 'video_interest_mount.dart';
import 'video_state_card.dart';

/// [view] (a tile for [identity]) with its status cards: a share's stall and
/// pause states, the health chip, and the paused card over the member's own preview.
/// While mounted it keeps the feed subscribed, unless [declaresInterest] is false (the canvas states its own).
Widget voiceVideoView({
  required List<VoiceParticipant> participants,
  required ValueListenable<Map<String, VideoTileHealth>> health,
  required String identity,
  required Widget view,
  required bool screenShare,
  bool declaresInterest = true,
}) {
  final who = participants.where((p) => p.identity == identity).firstOrNull;
  final name = who?.name ?? 'Someone';
  if (screenShare) {
    view = ScreenShareStatusScope(
      builder: (context, status) => screenShareStatusCard(
        context: context,
        status: status,
        identity: identity,
        name: name,
      ),
      child: view,
    );
  }
  final tileKey = videoSubscriptionKey(
    identity: identity,
    screenShare: screenShare,
  );
  view = VideoHealthOverlay(
    health: health,
    tileKey: tileKey,
    sharerName: screenShare ? name : null,
    sharerIdentity: identity,
    child: view,
  );
  if (who?.isLocal == true) {
    view = LocalPreviewGate(
      identity: identity,
      name: name,
      screenShare: screenShare,
      child: view,
    );
  }
  return declaresInterest
      ? VideoInterestMount(tileKey: tileKey, child: view)
      : view;
}

class VideoHealthOverlay extends StatelessWidget {
  const VideoHealthOverlay({
    super.key,
    required this.health,
    required this.tileKey,
    required this.child,
    this.sharerName,
    this.sharerIdentity,
  });

  /// Set for a screen share: a stalled one then gets a card over its dimmed last frame.
  final String? sharerName;
  final String? sharerIdentity;

  /// [VoiceSession.videoHealth].
  final ValueListenable<Map<String, VideoTileHealth>> health;

  /// The tile's `<kind>:<identity>` key.
  final String tileKey;

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Map<String, VideoTileHealth>>(
      valueListenable: health,
      child: child,
      builder: (context, states, child) {
        final state = states[tileKey] ?? VideoTileHealth.playing;
        // Always the same Stack, so a label coming or going never remounts the video under it.
        return Stack(
          // Passthrough and a fixed corner keep the video's own layout exactly as without the overlay.
          fit: StackFit.passthrough,
          alignment: Alignment.topLeft,
          children: [
            child!,
            // Centred: the tile's corners hold its name, mic badge and pop-out button.
            if (state != VideoTileHealth.playing)
              Positioned.fill(child: _overlayFor(state)),
          ],
        );
      },
    );
  }

  Widget _overlayFor(VideoTileHealth state) {
    final name = sharerName;
    final stalled = state == VideoTileHealth.stalled;
    if (name == null || (!stalled && state != VideoTileHealth.stopped)) {
      return Center(child: _HealthLabel(state: state));
    }
    return VideoStateCard(
      icon: stalled ? AppIcons.screenShare : AppIcons.screenShareStop,
      title: stalled ? 'Reconnecting screen share' : 'Not being captured',
      subtitle: stalled
          ? "$name's screen stopped sending frames"
          : "$name's screen is not producing frames",
      identity: sharerIdentity ?? '',
      name: name,
      dimsVideoBehind: true,
    );
  }
}

class _HealthLabel extends StatelessWidget {
  const _HealthLabel({required this.state});

  final VideoTileHealth state;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final (label, leading) = switch (state) {
      VideoTileHealth.paused => (
        'Paused',
        Icon(AppIcons.pause, size: 12, color: tokens.textSecondary),
      ),
      VideoTileHealth.stalled => (
        'Reconnecting video',
        SizedBox.square(
          dimension: 12,
          child: CircularProgressIndicator(
            strokeWidth: 1.5,
            color: tokens.textSecondary,
          ),
        ),
      ),
      _ => (
        'Video stopped',
        Icon(AppIcons.cameraOff, size: 12, color: tokens.textSecondary),
      ),
    };
    return Semantics(
      label: label,
      container: true,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: tokens.surfaceRaised,
            borderRadius: BorderRadius.circular(AppRadii.control),
            border: Border.all(color: tokens.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              leading,
              const SizedBox(width: AppSpacing.s4),
              Text(
                label,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
