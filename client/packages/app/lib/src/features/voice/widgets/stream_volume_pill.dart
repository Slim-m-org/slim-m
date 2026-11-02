// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A shared screen's own volume, on a raised pill so it reads over any picture.
///
/// Shared by the pop-out window, the share stage's control strip and the full
/// screen view, which all lay it over video.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show LocalAudioChannel;

import '../providers/voice_controller.dart';
import 'participant_audio_controls.dart' show ParticipantVolumeControl;
import 'stream_control_pill.dart';

const double kStreamVolumeMaxWidth = 260;

class StreamVolumePill extends StatelessWidget {
  const StreamVolumePill({
    super.key,
    required this.identity,
    required this.controller,
    this.onHold,
  });

  final String identity;
  final VoiceController controller;

  /// Told true while a finger or button is down on the pill, so a reveal around it stays up through a drag.
  final ValueChanged<bool>? onHold;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kStreamVolumeMaxWidth),
      child: Listener(
        onPointerDown: (_) => onHold?.call(true),
        onPointerUp: (_) => onHold?.call(false),
        onPointerCancel: (_) => onHold?.call(false),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
          child: StreamControlPill(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.s8),
            child: Row(
              children: [
                Icon(
                  AppIcons.speaker,
                  size: AppSizes.icon16,
                  color: tokens.textSecondary,
                ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: ParticipantVolumeControl(
                    identity: identity,
                    controller: controller,
                    channel: LocalAudioChannel.screen,
                    showLabel: false,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
