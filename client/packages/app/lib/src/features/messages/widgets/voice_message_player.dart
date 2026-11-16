// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice message on a message row: play or pause, the waveform with the
/// played part filled, how long it is, and the playback speed.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../../../downloads/downloads_controller.dart';
import '../../../widgets/context_menu_region.dart';
import '../../../widgets/voice_waveform.dart';
import '../providers/voice_playback.dart';
import '../providers/voice_transcripts.dart';
import 'voice_transcript_line.dart';

/// Wide enough for a minute of speech to read, narrow enough to stay a chip.
const double kVoicePlayerMaxWidth = 320;

/// How far an arrow key or a screen reader moves the playhead.
const Duration _seekStep = Duration(seconds: 5);

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
      voicePlaybackProvider.select((s) => s.errorFor == id ? s.error : null),
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
          ContextMenuRegion(
            itemsBuilder: (context, close) => _menuItems(ref, close),
            child: Container(
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
                  AppIconButton(
                    icon: playing ? AppIcons.pause : AppIcons.play,
                    busy: loading,
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
                      position: position,
                      total: total,
                      onSeek: (at) =>
                          unawaited(playback.seekTo(attachment, at)),
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
          ),
          VoiceTranscriptLine(attachment: attachment),
          if (error != null) ...[
            const SizedBox(height: AppSpacing.s4),
            switch (error) {
              VoicePlaybackError.inCall => Text(
                'Leave the call to play a voice message.',
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
              VoicePlaybackError.unplayable => AppErrorState(
                message: 'The voice message could not be played.',
                onRetry: () => unawaited(playback.toggle(attachment)),
                onDismiss: playback.dismissError,
              ),
            },
          ],
        ],
      ),
    );
  }

  List<Widget> _menuItems(WidgetRef ref, VoidCallback close) {
    final words = voiceTranscriptWords(
      attachment,
      ref.read(voiceTranscriptsProvider)[attachment.id],
    );
    return [
      if (words != null)
        AppMenuItem(
          label: 'Copy transcript',
          leading: AppIcons.copy,
          onTap: () {
            close();
            unawaited(Clipboard.setData(ClipboardData(text: words)));
          },
        ),
      AppMenuItem(
        label: 'Save voice message',
        leading: AppIcons.download,
        onTap: () {
          close();
          unawaited(ref.read(downloadsProvider.notifier).start(attachment));
        },
      ),
    ];
  }
}

/// Tap or drag along the waveform to move the playhead; the arrow keys and a
/// screen reader move it a step at a time.
class _Seekable extends StatelessWidget {
  const _Seekable({
    super.key,
    required this.enabled,
    required this.position,
    required this.total,
    required this.onSeek,
    required this.child,
  });

  final bool enabled;
  final Duration position;
  final Duration total;
  final ValueChanged<Duration> onSeek;
  final Widget child;

  Duration _stepped(int direction) {
    final at = (position + _seekStep * direction).inMilliseconds;
    return Duration(milliseconds: at.clamp(0, total.inMilliseconds));
  }

  String _spoken(Duration at) =>
      '${formatVoiceDuration(at)} of ${formatVoiceDuration(total)}';

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowRight => 1,
      LogicalKeyboardKey.arrowLeft => -1,
      _ => 0,
    };
    if (direction == 0) return KeyEventResult.ignored;
    onSeek(_stepped(direction));
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) => Semantics(
    slider: true,
    enabled: enabled,
    label: 'Voice message position',
    value: _spoken(position),
    increasedValue: _spoken(_stepped(1)),
    decreasedValue: _spoken(_stepped(-1)),
    onIncrease: enabled ? () => onSeek(_stepped(1)) : null,
    onDecrease: enabled ? () => onSeek(_stepped(-1)) : null,
    child: AppFocusRing(
      radius: AppRadii.control,
      builder: (context, onFocusChange) => Focus(
        canRequestFocus: enabled,
        skipTraversal: !enabled,
        onFocusChange: onFocusChange,
        onKeyEvent: _onKey,
        child: LayoutBuilder(
          builder: (context, box) {
            void seek(Offset at) =>
                onSeek(total * (at.dx / box.maxWidth).clamp(0.0, 1.0));
            if (!enabled) return child;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => seek(d.localPosition),
              onHorizontalDragUpdate: (d) => seek(d.localPosition),
              child: child,
            );
          },
        ),
      ),
    ),
  );
}

class _SpeedButton extends StatelessWidget {
  const _SpeedButton({required this.speed, required this.onTap});

  final double speed;
  final VoidCallback onTap;

  static String _label(double speed) =>
      speed == speed.roundToDouble() ? '${speed.round()}x' : '${speed}x';

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final style = AppText.caption.copyWith(color: tokens.accent);
    final widest = kVoiceSpeeds
        .map(_label)
        .reduce((a, b) => b.length > a.length ? b : a);
    return FocusableTapTarget(
      key: const Key('voice-player-speed'),
      semanticLabel: 'Playback speed ${_label(speed)}',
      ringRadius: AppRadii.full,
      onTap: onTap,
      builder: (context, focused, hovered) => ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.s8,
            vertical: AppSpacing.s4,
          ),
          decoration: BoxDecoration(
            color: tokens.accentSoft,
            borderRadius: BorderRadius.circular(AppRadii.full),
          ),
          // Sized to the widest speed, so cycling never moves the waveform.
          child: Stack(
            alignment: Alignment.center,
            children: [
              Visibility.maintain(
                visible: false,
                child: Text(widest, style: style),
              ),
              Text(_label(speed), style: style),
            ],
          ),
        ),
      ),
    );
  }
}
