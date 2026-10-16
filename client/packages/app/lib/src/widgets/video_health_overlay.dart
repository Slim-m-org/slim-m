// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A small label over a remote video tile when its picture is not live:
/// paused by the server, stalled while recovery runs, or stopped. Nothing at
/// all while the video plays, so a healthy tile is untouched.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

/// [view] (a remote tile for [identity]) with its [VideoHealthOverlay].
Widget withVideoHealth(
  ValueListenable<Map<String, VideoTileHealth>> health,
  String identity,
  Widget view, {
  required bool screenShare,
}) => VideoHealthOverlay(
  health: health,
  tileKey: videoSubscriptionKey(identity: identity, screenShare: screenShare),
  child: view,
);

class VideoHealthOverlay extends StatelessWidget {
  const VideoHealthOverlay({
    super.key,
    required this.health,
    required this.tileKey,
    required this.child,
  });

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
            if (state != VideoTileHealth.playing)
              Positioned(
                left: AppSpacing.s8,
                bottom: AppSpacing.s8,
                child: _HealthLabel(state: state),
              ),
          ],
        );
      },
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
            ExcludeSemantics(
              child: Text(
                label,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
