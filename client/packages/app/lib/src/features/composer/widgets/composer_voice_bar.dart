// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the composer's row becomes while a voice message is recorded: discard,
/// a running clock with the live level, and send.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/voice_waveform.dart';
import '../providers/voice_recording.dart';
import 'composer_attachments.dart';

/// Called with the staging of the channel the voice message was recorded in,
/// which now holds it, uploaded.
typedef VoiceSent = void Function(AttachmentStagingController staging);

/// The mic that stands in for Send. It wakes a moment after it appears, so the
/// second click of a double-click on Send cannot land on it and start recording.
class ComposerMicButton extends StatefulWidget {
  const ComposerMicButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  /// How long a fresh mic ignores presses.
  static const wakeDelay = Duration(milliseconds: 600);

  @override
  State<ComposerMicButton> createState() => _ComposerMicButtonState();
}

class _ComposerMicButtonState extends State<ComposerMicButton> {
  late final Timer _wake;
  bool _awake = false;

  @override
  void initState() {
    super.initState();
    _wake = Timer(ComposerMicButton.wakeDelay, () {
      if (mounted) setState(() => _awake = true);
    });
  }

  @override
  void dispose() {
    _wake.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AppIconButton(
    icon: AppIcons.mic,
    semanticLabel: 'Record a voice message',
    tooltip: 'Record a voice message',
    onPressed: _awake ? widget.onPressed : null,
  );
}

class ComposerVoiceBar extends ConsumerWidget {
  const ComposerVoiceBar({
    super.key,
    required this.channelId,
    required this.onSent,
  });

  final String channelId;
  final VoiceSent onSent;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final state = ref.watch(voiceRecorderProvider(channelId));
    final recorder = ref.read(voiceRecorderProvider(channelId).notifier);
    final uploading = state.phase == VoicePhase.uploading;
    final canSend =
        state.phase == VoicePhase.recording ||
        state.phase == VoicePhase.stopped ||
        (state.phase == VoicePhase.failed && state.clip != null);
    // A refusal or a failed start holds no clip, so its Send can never act and a screen reader should not find it.
    final nothingToSend =
        state.phase == VoicePhase.failed && state.clip == null;
    return Row(
      key: const Key('composer-voice-bar'),
      children: [
        AppIconButton(
          icon: AppIcons.delete,
          semanticLabel: 'Discard voice message',
          tooltip: 'Discard voice message',
          variant: AppIconButtonVariant.dangerGhost,
          onPressed: uploading ? null : recorder.cancel,
        ),
        const SizedBox(width: AppSpacing.s8),
        Expanded(
          child: _Body(state: state, tokens: tokens),
        ),
        const SizedBox(width: AppSpacing.s8),
        ExcludeSemantics(
          excluding: nothingToSend,
          child: AppIconButton(
            icon: AppIcons.send,
            semanticLabel: 'Send voice message',
            tooltip: 'Send voice message',
            onPressed: canSend ? () => _send(ref, recorder) : null,
          ),
        ),
      ],
    );
  }

  Future<void> _send(WidgetRef ref, VoiceRecorder recorder) async {
    // Read before the upload, which a channel switch can outlast.
    final staging = ref.read(attachmentStagingProvider(channelId));
    final sent = await recorder.send();
    if (sent == null) return;
    staging.addResolved(sent.$1, sent.$2);
    onSent(staging);
  }
}

class _Body extends StatelessWidget {
  const _Body({required this.state, required this.tokens});

  final VoiceRecordingState state;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final error = state.error;
    if (error != null) {
      return AppErrorState(
        key: const Key('composer-voice-error'),
        message: error,
      );
    }
    final remaining = kVoiceMaxDuration - state.elapsed;
    final nearCap =
        state.phase == VoicePhase.recording &&
        remaining <= const Duration(seconds: 30);
    final label = switch (state.phase) {
      VoicePhase.uploading => 'Sending',
      VoicePhase.starting => 'Starting',
      _ when state.hitCap => '${formatVoiceDuration(state.elapsed)} limit',
      _ => formatVoiceDuration(state.elapsed),
    };
    return Row(
      children: [
        if (state.phase == VoicePhase.recording)
          Container(
            key: const Key('composer-voice-dot'),
            width: 8,
            height: 8,
            margin: const EdgeInsets.only(right: AppSpacing.s8),
            decoration: BoxDecoration(
              color: tokens.dangerText,
              shape: BoxShape.circle,
            ),
          ),
        Text(
          label,
          key: const Key('composer-voice-clock'),
          style: AppText.ui.copyWith(
            fontFamily: AppFonts.mono,
            color: nearCap ? tokens.warnText : tokens.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
        if (state.stoppedForCall) ...[
          const SizedBox(width: AppSpacing.s8),
          Text(
            'Stopped for a call',
            key: const Key('composer-voice-call-note'),
            maxLines: 1,
            style: AppText.caption.copyWith(color: tokens.textSecondary),
          ),
        ],
        const SizedBox(width: AppSpacing.s12),
        Expanded(
          child: _Meter(state: state, tokens: tokens),
        ),
      ],
    );
  }
}

class _Meter extends StatelessWidget {
  const _Meter({required this.state, required this.tokens});

  final VoiceRecordingState state;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final clip = state.clip;
    final values = clip != null
        ? [for (final v in clip.waveform) v / 255]
        : [
            // Padded to a full meter so bars enter from the right.
            for (var i = state.levels.length; i < kVoiceMeterBars; i++) 0.0,
            ...state.levels,
          ];
    return VoiceWaveform(
      values: values,
      playedColor: tokens.accent,
      restColor: tokens.accent,
      progress: 1,
    );
  }
}
