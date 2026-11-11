// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Transcript lines as a palette group (decision 0113): the hit rows, and what
/// choosing one does - open that voice channel's idle pane on the call and
/// ask it to scroll to the line.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/routes.dart';
import '../../members/providers/user_profiles.dart';
import '../../messages/widgets/message_row_identity.dart' show formatMessageDay;
import '../../voice/providers/call_transcript.dart';
import 'command_palette_items.dart';
import 'palette_highlight.dart';

List<PaletteResultItem> buildTranscriptItems(
  List<api.TranscriptHit> hits, {
  Map<String, Channel> channelsById = const {},
}) => [
  for (final hit in hits)
    PaletteResultItem(
      label: hit.text,
      kind: PaletteKind.transcript,
      transcript: hit,
      messageChannelLabel: paletteChannelLabel(channelsById[hit.channelId]),
      onSelect: (context, ref) async => openTranscriptHit(
        GoRouter.of(context),
        ref.read(transcriptFocusProvider.notifier),
        hit,
      ),
    ),
];

/// Arrives to read, never to join, and leaves the line for the pane to find.
void openTranscriptHit(
  GoRouter router,
  StateController<TranscriptFocus?> focus,
  api.TranscriptHit hit,
) {
  focus.state = (
    channelId: hit.channelId,
    transcriptId: hit.transcriptId,
    seq: hit.seq,
  );
  router.go(Routes.channel(hit.channelId, openChat: true));
}

/// One transcript hit: the line, then who said it, where and when.
class PaletteTranscriptBody extends ConsumerWidget {
  const PaletteTranscriptBody({
    super.key,
    required this.hit,
    required this.channelLabel,
    required this.query,
    required this.lines,
  });

  final api.TranscriptHit hit;
  final String channelLabel;
  final String query;

  /// Lines the text may take: a phone row has two.
  final int lines;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final name =
        ref
            .watch(userProfileProvider(hit.speakerId))
            .valueOrNull
            ?.displayName ??
        'Someone';
    final day = formatMessageDay(hit.at);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      spacing: AppSpacing.s12,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(
            AppIcons.callAudio,
            size: AppSizes.icon16,
            color: tokens.textSecondary,
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              paletteHighlightedWords(
                hit.text,
                query,
                AppText.ui.copyWith(color: tokens.textPrimary),
                maxLines: lines,
              ),
              Text(
                '$name · $channelLabel · $day',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppText.caption.copyWith(color: tokens.textSecondary),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
