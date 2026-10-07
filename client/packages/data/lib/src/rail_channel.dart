// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The channel-rail projection `MessageStore.watchRailChannels` dedupes
/// against - split out once adding it to `message_store.dart` crossed the
/// review budget.
library;

import 'database.dart';

/// The fields of a [Channel] the channel rail draws from: what
/// `channel_rail.dart` and its row widgets render or group by. Records
/// compare structurally, so two keys are `==` exactly when the rail would
/// render them identically.
///
/// `unread` and `mentioned` are derived rather than the raw
/// `cursor`/`mentionedSeq`/`lastReadSeq` behind them: a channel already
/// unread (or already mentioned) stays that way through every further
/// message, so only the flip in or out of either state belongs in the key.
///
/// Deliberately broader than what a row paints, which a notification override
/// can quieten (`providers/unread_indicator_rules.dart`): this key only
/// decides whether the rail stream re-emits, and an emission that turns out
/// to draw nothing new is free where a missed one leaves a stale rail.
typedef RailChannelKey = ({
  String id,
  String name,
  String kind,
  int position,
  String? categoryId,
  bool isPersonalSpace,
  String? dmParticipantId,
  bool? restricted,
  bool unread,
  bool mentioned,
});

RailChannelKey railChannelKey(Channel channel) => (
      id: channel.id,
      name: channel.name,
      kind: channel.kind,
      position: channel.position,
      categoryId: channel.categoryId,
      isPersonalSpace: channel.isPersonalSpace,
      dmParticipantId: channel.dmParticipantId,
      restricted: channel.restricted,
      unread: channel.cursor > channel.lastReadSeq ||
          (channel.manuallyUnread ?? false),
      mentioned: channel.mentionedSeq > channel.lastReadSeq,
    );

/// `Stream.distinct`'s callback for `MessageStore.watchRailChannels`: true
/// drops the newer emission, so this is true when [a] and [b] would draw
/// the same rail, row for row and in the same order.
bool railChannelsUnchanged(List<Channel> a, List<Channel> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (railChannelKey(a[i]) != railChannelKey(b[i])) return false;
  }
  return true;
}
