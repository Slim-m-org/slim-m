// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message on a message row: play or pause, the waveform with the
/// played part filled, how long it is, and the playback speed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/voice_waveform.dart';
import '../providers/voice_playback.dart';

/// Wide enough for a minute of speech to read, narrow enough to stay a chip.
const double kVoicePlayerMaxWidth = 320;

class VoiceMessagePlayer extends ConsumerWidget {
  const VoiceMessagePlayer({super.key, required this.attachment});

  final api.Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final voice = attachment.voice!;
    final id = attachment.id;
    final mine = ref.watch(
      voicePlaybackProvider.select((s) => s.attachmentId == id),
    );
    final loading = ref.watch(
      voicePlaybackProvider.select((s) => mine && s.loading),
    );
    final playing = ref.watch(
      voicePlaybackProvider.select((s) => mine && s.playing),
    );
    final position = ref.watch(
      voicePlaybackProvider.select((s) => mine ? s.position : Duration.zero),
    );
    final speed = ref.watch(voicePlaybackProvider.select((s) => s.speed));
    final error = ref.watch(
      voicePlaybackProvider.select(
        (s) => s.attachmentId == null ? s.error : null,
      ),
    );
    final playback = ref.read(voicePlaybackProvider.notifier);
    final total = voice.duration;
    final progress = total.inMilliseconds == 0
        ? 0.0
        : (position.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0);
    final label = (playing || position > Duration.zero) ? position : total;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: kVoicePlayerMaxWidth),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            key: ValueKey('voice-player-$id'),
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.s8,
              AppSpacing.s8,
              AppSpacing.s12,
              AppSpacing.s8,
            ),
            decoration: BoxDecoration(
              color: tokens.surfaceRaised,
              border: Border.all(color: tokens.borderSubtle),
              borderRadius: BorderRadius.circular(AppRadii.card),
            ),
            child: Row(
              children: [
                loading
                    ? const SizedBox(
                        width: AppSizes.controlLg,
                        height: AppSizes.controlLg,
                        child: Center(
                          child: AppSpinner(size: AppSpinnerSize.sm),
                        ),
                      )
                    : AppIconButton(
                        icon: playing ? AppIcons.pause : AppIcons.play,
                        semanticLabel: playing
                            ? 'Pause voice message'
                            : 'Play voice message',
                        tooltip: playing ? 'Pause' : 'Play',
                        onPressed: () => unawaited(playback.toggle(attachment)),
                      ),
                const SizedBox(width: AppSpacing.s8),
                Expanded(
                  child: _Seekable(
                    key: const Key('voice-player-wave'),
                    enabled: mine && !loading,
                    onSeek: (fraction) => unawaited(
                      playback.seekTo(
                        attachment,
                        Duration(
                          milliseconds: (total.inMilliseconds * fraction)
                              .round(),
                        ),
                      ),
                    ),
                    child: VoiceWaveform(
                      values: [for (final v in voice.waveform) v / 255],
                      playedColor: tokens.accent,
                      restColor: tokens.borderStrong,
                      progress: progress,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                Text(
                  formatVoiceDuration(label),
                  key: const Key('voice-player-time'),
                  style: AppText.caption.copyWith(
                    color: tokens.textSecondary,
                    fontFamily: AppFonts.mono,
                  ),
                ),
                const SizedBox(width: AppSpacing.s8),
                _SpeedButton(speed: speed, onTap: playback.cycleSpeed),
              ],
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.s4),
            Text(
              error,
              style: AppText.caption.copyWith(color: tokens.dangerText),
            ),
          ],
        ],
      ),
    );
  }
}

/// Tap or drag along the waveform to move the playhead.
class _Seekable extends StatelessWidget {
  const _Seekable({
    super.key,
    required this.enabled,
    required this.onSeek,
    required this.child,
  });

  final bool enabled;
  final ValueChanged<double> onSeek;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, box) {
      void seek(Offset at) => onSeek((at.dx / box.maxWidth).clamp(0.0, 1.0));
      if (!enabled) return child;
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => seek(d.localPosition),
        onHorizontalDragUpdate: (d) => seek(d.localPosition),
        child: child,
      );
    },
  );
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onTap});

  final double speed;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final text = speed == speed.roundToDouble()
        ? '${speed.round()}x'
        : '${speed}x';
    return Semantics(
      button: true,
      label: 'Playback speed $text',
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        key: const Key('voice-player-speed'),
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            minWidth: AppSizes.controlLg,
            minHeight: AppTouchTargets.of(context)
                ? AppSizes.rowTouch
                : AppSizes.controlSm,
          ),
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.s8,
                vertical: AppSpacing.s4,
              ),
              decoration: BoxDecoration(
                color: tokens.accentSoft,
                borderRadius: BorderRadius.circular(AppRadii.full),
              ),
              child: Text(
                text,
                style: AppText.caption.copyWith(color: tokens.accent),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
