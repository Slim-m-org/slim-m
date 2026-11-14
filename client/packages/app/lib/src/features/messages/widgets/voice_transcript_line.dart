// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under a voice message's player: "Transcribing..." while the server
/// works, then what was said, shown in full.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_transcripts.dart';

class VoiceTranscriptLine extends ConsumerWidget {
  const VoiceTranscriptLine({super.key, required this.attachment});

  final api.Attachment attachment;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final live = ref.watch(
      voiceTranscriptsProvider.select((all) => all[attachment.id]),
    );
    final transcript = live ?? attachment.transcript;
    if (transcript == null) return const SizedBox.shrink();
    final muted = AppText.caption.copyWith(color: tokens.textSecondary);
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.s4),
      child: switch (transcript.status) {
        api.VoiceTranscriptStatus.pending => Row(
          key: const Key('voice-transcript-pending'),
          mainAxisSize: MainAxisSize.min,
          children: [
            const AppSpinner(size: AppSpinnerSize.sm),
            const SizedBox(width: AppSpacing.s8),
            Text('Transcribing...', style: muted),
          ],
        ),
        api.VoiceTranscriptStatus.failed => Text(
          'Could not transcribe this message.',
          key: const Key('voice-transcript-failed'),
          style: muted,
        ),
        api.VoiceTranscriptStatus.ready when transcript.text.isEmpty => Text(
          'No speech heard',
          key: const Key('voice-transcript-silent'),
          style: muted,
        ),
        api.VoiceTranscriptStatus.ready => SelectableText(
          transcript.text,
          key: const Key('voice-transcript-text'),
          style: AppText.ui.copyWith(color: tokens.textPrimary),
        ),
      },
    );
  }
}
