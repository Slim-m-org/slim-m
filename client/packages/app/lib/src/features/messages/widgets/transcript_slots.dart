// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two stand-ins the transcript shows around its rows: the slot above the
/// loaded window and the body of a transcript with no messages.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../providers/sync_status.dart';
import '../../channels/providers/channel_history.dart';
import 'message_transcript_widgets.dart';

/// The slot at the very top of the loaded window: always present, never
/// absent, so the list's own item count never shifts by one right where the
/// reader is scrolled when a page lands - only what fills it changes.
///
/// Returning null here for a DM once history reached its true start used to
/// be exactly that shift: paging only ever triggers near the far end of the
/// loaded list, so the one item that could vanish always vanished right
/// under the reader's own scroll offset. [ChannelStartHeader] renders
/// generic copy for a DM now instead of nothing, closing the gap without
/// reopening the "Welcome to # a person's name" wording it was never meant
/// to say.
class TranscriptTopSlot extends StatelessWidget {
  const TranscriptTopSlot({
    super.key,
    required this.history,
    required this.onRetryOlder,
    required this.channelName,
    required this.channelTopic,
    required this.channelIsThread,
    required this.channelIsVoice,
    required this.threadParent,
  });

  final ChannelHistory history;
  final VoidCallback onRetryOlder;
  final String? channelName;
  final String? channelTopic;
  final bool channelIsThread;
  final bool channelIsVoice;
  final Widget? threadParent;

  @override
  Widget build(BuildContext context) {
    if (!history.atStart) {
      return HistoryTopAffordance(
        failed: history.failed,
        loading: history.loading,
        onRetry: onRetryOlder,
      );
    }
    if (channelIsThread) return threadParent ?? const SizedBox.shrink();
    return ChannelStartHeader(
      name: channelName,
      topic: channelTopic,
      isThread: channelIsThread,
      isVoice: channelIsVoice,
    );
  }
}

/// The transcript body when there are no messages to lay out.
class EmptyTranscript extends StatelessWidget {
  const EmptyTranscript({
    super.key,
    required this.start,
    required this.shrinkWrap,
    required this.syncStatus,
    required this.scrollController,
    required this.channelIsThread,
    required this.threadParent,
  });

  final Widget start;
  final bool shrinkWrap;
  final SyncStatus syncStatus;
  final ScrollController? scrollController;
  final bool channelIsThread;
  final Widget? threadParent;

  @override
  Widget build(BuildContext context) {
    // Reverse-anchored like the populated list, so the welcome sits above the composer, not at the top of an empty pane.
    if (syncStatus == SyncStatus.live) {
      return ListView(
        controller: scrollController,
        reverse: true,
        shrinkWrap: shrinkWrap,
        padding: const EdgeInsets.only(bottom: AppSpacing.s8),
        children: [
          if (channelIsThread)
            const ChannelStartHeader(name: null, isThread: true),
          start,
        ],
      );
    }
    final waiting = EmptyMessages(syncStatus: syncStatus);
    if (!channelIsThread) return waiting;
    // The parent is known without the sync, so it shows even while the replies cannot.
    return Column(
      children: [
        threadParent ?? const SizedBox.shrink(),
        Expanded(child: waiting),
      ],
    );
  }
}
