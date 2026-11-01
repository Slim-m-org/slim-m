// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transport bar [VideoPlaybackControls] fades in and out: scrubber,
/// play/pause, time, save, volume and the full screen toggle.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../format.dart' show formatPlaybackTime;
import '../../messages/widgets/swipe_to_reply.dart' show SwipeToReplyOptOut;

/// Width of the inline volume slider beside the speaker button.
const double kVideoVolumeSliderWidth = 72;

class VideoControlsBar extends StatelessWidget {
  const VideoControlsBar({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.scrubMs,
    required this.volume,
    required this.isFullscreen,
    required this.saving,
    required this.onPlayPause,
    required this.onScrub,
    required this.onToggleMute,
    required this.onVolume,
    required this.onToggleFullscreen,
    required this.onSave,
  });

  final bool playing;
  final Duration position;
  final Duration duration;
  final double? scrubMs;

  /// 0 to 100, the range `Player.setVolume` takes.
  final double volume;
  final bool isFullscreen;
  final bool saving;
  final VoidCallback onPlayPause;
  final ValueChanged<double> onScrub;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleFullscreen;

  /// Null hides the save button, for a surface with nothing to save.
  final VoidCallback? onSave;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final durationMs = duration.inMilliseconds.toDouble();
    final hasDuration = durationMs > 0;
    final sliderValue = (scrubMs ?? position.inMilliseconds.toDouble()).clamp(
      0.0,
      hasDuration ? durationMs : 1.0,
    );
    final remaining = duration - position;
    final timeStyle = AppText.caption.copyWith(
      color: tokens.textPrimary,
      fontFamily: AppFonts.mono,
      fontWeight: AppWeights.regular,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    final muted = volume <= 0;
    // Phones have hardware volume keys; a pointer has nothing else to turn it down with.
    final showVolumeSlider = !AppTouchTargets.of(context);

    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0),
            Colors.black.withValues(alpha: 0.75),
          ],
        ),
      ),
      child: SafeArea(
        top: false,
        minimum: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.s8,
            AppSpacing.s24,
            AppSpacing.s8,
            AppSpacing.s4,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SwipeToReplyOptOut(
                child: AppSlider(
                  value: sliderValue,
                  max: hasDuration ? durationMs : 1,
                  onChanged: hasDuration ? onScrub : null,
                  semanticLabel: 'Seek',
                ),
              ),
              Row(
                children: [
                  AppIconButton(
                    icon: playing ? AppIcons.pause : AppIcons.play,
                    semanticLabel: playing ? 'Pause' : 'Play',
                    variant: AppIconButtonVariant.ghost,
                    onPressed: onPlayPause,
                  ),
                  Flexible(
                    child: Text(
                      '${formatPlaybackTime(position)} / '
                      '-${formatPlaybackTime(remaining)}',
                      maxLines: 1,
                      overflow: TextOverflow.clip,
                      style: timeStyle,
                    ),
                  ),
                  const Spacer(),
                  if (onSave case final save?)
                    saving
                        ? const Padding(
                            padding: EdgeInsets.all(AppSpacing.s8),
                            child: AppSpinner(size: AppSpinnerSize.sm),
                          )
                        : AppIconButton(
                            icon: AppIcons.download,
                            semanticLabel: 'Save video',
                            tooltip: 'Save',
                            variant: AppIconButtonVariant.ghost,
                            onPressed: save,
                          ),
                  AppIconButton(
                    icon: muted ? AppIcons.speakerOff : AppIcons.speaker,
                    semanticLabel: muted ? 'Unmute' : 'Mute',
                    variant: AppIconButtonVariant.ghost,
                    onPressed: onToggleMute,
                  ),
                  if (showVolumeSlider)
                    SizedBox(
                      width: kVideoVolumeSliderWidth,
                      child: SwipeToReplyOptOut(
                        child: AppSlider(
                          value: volume.clamp(0, 100),
                          max: 100,
                          keyStep: 5,
                          onChanged: onVolume,
                          semanticLabel: 'Volume',
                        ),
                      ),
                    ),
                  AppIconButton(
                    icon: isFullscreen ? AppIcons.collapse : AppIcons.expand,
                    semanticLabel: isFullscreen
                        ? 'Exit full screen'
                        : 'Full screen',
                    variant: AppIconButtonVariant.ghost,
                    onPressed: onToggleFullscreen,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
