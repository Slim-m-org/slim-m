// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What is waiting for the reader across the Space: channels with an unread
/// mention first, then the rest that are unread, built from the local store.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import 'unread_indicator_rules.dart';

/// One channel with something waiting. [message] is the mention when
/// [mentioned], else the channel's newest message; null when not held locally.
class InboxEntry {
  const InboxEntry({
    required this.channel,
    required this.mentioned,
    required this.unread,
    this.message,
  });

  final Channel channel;
  final bool mentioned;
  final int unread;
  final Message? message;
}

/// Entries shown at most, so a long absence cannot build a thousand rows.
const inboxLimit = 100;

/// Channels the rail would light, in the order the inbox lists them.
Future<List<InboxEntry>> buildInbox(
  MessageStore store,
  Iterable<Channel> channels,
  ChannelNotificationOverridesState overrides,
) async {
  final entries = <InboxEntry>[];
  for (final channel in channels) {
    final indicator = unreadIndicatorFor(
      channelOverride: overrides.overrideFor(channel.id),
      isDm: channel.dmParticipantId != null,
      unread: channel.cursor > channel.lastReadSeq,
      mentioned: channel.mentionedSeq > channel.lastReadSeq,
      manuallyUnread: channel.manuallyUnread ?? false,
    );
    if (!indicator.unread && !indicator.mentioned) continue;
    entries.add(
      InboxEntry(
        channel: channel,
        mentioned: indicator.mentioned,
        unread: channel.cursor - channel.lastReadSeq,
        message: indicator.mentioned
            ? await store.messageAtSeq(channel.id, channel.mentionedSeq)
            : await _newest(store, channel.id),
      ),
    );
  }
  entries.sort((a, b) {
    if (a.mentioned != b.mentioned) return a.mentioned ? -1 : 1;
    return (b.message?.createdAt ?? 0).compareTo(a.message?.createdAt ?? 0);
  });
  return entries.take(inboxLimit).toList(growable: false);
}

Future<Message?> _newest(MessageStore store, String channelId) async {
  final latest = await store.channelSnapshot(channelId, limit: 1);
  return latest.isEmpty ? null : latest.last;
}

final inboxProvider = StreamProvider.autoDispose<List<InboxEntry>>((
  ref,
) async* {
  final store = await ref.watch(storeProvider.future);
  final overrides = ref.watch(channelNotificationOverridesProvider);
  yield* store.watchChannels().asyncMap(
    (channels) => buildInbox(store, channels, overrides),
  );
});
