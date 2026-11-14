// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The line under a voice message's player: "Transcribing..." while the server
/// works, then a "Transcript" row that opens to what was said.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_design_system/design_system.dart';

import '../providers/voice_transcripts.dart';

class VoiceTranscriptLine extends ConsumerStatefulWidget {
  const VoiceTranscriptLine({super.key, required this.attachment});

  final api.Attachment attachment;

  @override
  ConsumerState<VoiceTranscriptLine> createState() =>
      _VoiceTranscriptLineState();
}

class _VoiceTranscriptLineState extends ConsumerState<VoiceTranscriptLine> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final live = ref.watch(
      voiceTranscriptsProvider.select((all) => all[widget.attachment.id]),
    );
    final transcript = live ?? widget.attachment.transcript;
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
        api.VoiceTranscriptStatus.ready => _ready(transcript.text, muted),
      },
    );
  }

  Widget _ready(String text, TextStyle muted) {
    final heard = text.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          button: true,
          expanded: _open,
          label: 'Transcript',
          excludeSemantics: true,
          onTap: heard ? _toggle : null,
          child: GestureDetector(
            key: const Key('voice-transcript-toggle'),
            behavior: HitTestBehavior.opaque,
            onTap: heard ? _toggle : null,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(heard ? 'Transcript' : 'No speech heard', style: muted),
                if (heard) ...[
                  const SizedBox(width: AppSpacing.s4),
                  Icon(
                    _open ? AppIcons.chevronUp : AppIcons.chevronDown,
                    size: AppSizes.icon12,
                    color: muted.color,
                  ),
                ],
              ],
            ),
          ),
        ),
        if (_open && heard)
          Padding(
            padding: const EdgeInsets.only(top: AppSpacing.s4),
            child: SelectableText(
              text,
              key: const Key('voice-transcript-text'),
              style: AppText.ui.copyWith(
                color: Theme.of(context).extension<AppTokens>()!.textPrimary,
              ),
            ),
          ),
      ],
    );
  }

  void _toggle() => setState(() => _open = !_open);
}
