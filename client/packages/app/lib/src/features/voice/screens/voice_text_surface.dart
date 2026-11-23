// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the voice channel's chat pane holds: the channel's chat, and while
/// the call is transcribed for this member (decision 0113), a "Chat |
/// Transcript" choice above it. The same surface fills the docked pane and the
/// compact swapped view (desktop-vs-mobile.md law 1 and rule 2).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../channels/screens/channel_screen.dart';
import '../providers/live_call_transcript.dart';
import '../providers/voice_text_tab.dart';
import '../widgets/live_transcript_view.dart';

const voiceTextTabsKey = Key('voice-text-tabs');

class VoiceTextSurface extends ConsumerWidget {
  const VoiceTextSurface({super.key, required this.channelId});

  final String channelId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // See ChannelScreen.showHeader's own doc for why this pane omits its own header.
    final chat = ChannelScreen(channelId: channelId, showHeader: false);
    final transcriptId = ref.watch(liveCallTranscriptIdProvider(channelId));
    if (transcriptId == null) return chat;
    final tab = ref.watch(voiceTextTabProvider);
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.s8),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: tokens.borderSubtle)),
          ),
          child: AppSegmentedControl.fill(
            key: voiceTextTabsKey,
            semanticLabel: 'Chat or transcript',
            options: const [
              AppSegmentedOption(label: 'Chat'),
              AppSegmentedOption(label: 'Transcript'),
            ],
            selectedIndex: tab.index,
            onSegmentSelected: (i) =>
                ref.read(voiceTextTabProvider.notifier).state =
                    VoiceTextTab.values[i],
          ),
        ),
        Expanded(
          child: tab == VoiceTextTab.chat
              ? chat
              : LiveTranscriptView(transcriptId: transcriptId),
        ),
      ],
    );
  }
}
