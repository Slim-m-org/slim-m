// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How much an account has waiting, for the switcher's badge.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';
import '../../channels/providers/channel_notification_overrides_controller.dart';
import '../../messages/providers/unread_indicator_rules.dart';

class AccountUnread {
  const AccountUnread({this.channels = 0, this.mentions = 0});

  static const none = AccountUnread();

  /// Channels showing as unread, mentions included.
  final int channels;

  /// Channels with an unread mention of this account.
  final int mentions;

  bool get any => channels > 0 || mentions > 0;

  @override
  bool operator ==(Object other) =>
      other is AccountUnread &&
      other.channels == channels &&
      other.mentions == mentions;

  @override
  int get hashCode => Object.hash(channels, mentions);
}

UnreadIndicator _indicatorOf(
  Channel channel,
  ChannelNotificationOverridesState overrides,
) => unreadIndicatorFor(
  channelOverride: overrides.effectiveFor(channel),
  isDm: channel.dmParticipantId != null,
  unread: channel.cursor > channel.lastReadSeq,
  mentioned: channel.mentionedSeq > channel.lastReadSeq,
  manuallyUnread: channel.manuallyUnread ?? false,
);

/// Counts what the rail would draw, so a muted channel never lights a badge.
AccountUnread countUnread(
  Iterable<Channel> channels,
  ChannelNotificationOverridesState overrides,
) {
  var unread = 0;
  var mentioned = 0;
  for (final channel in channels) {
    final indicator = _indicatorOf(channel, overrides);
    if (indicator.mentioned) mentioned++;
    if (indicator.unread || indicator.mentioned) unread++;
  }
  return AccountUnread(channels: unread, mentions: mentioned);
}

/// The ids of the channels the rail would draw as read.
Set<String> readChannelIds(
  Iterable<Channel> channels,
  ChannelNotificationOverridesState overrides,
) => {
  for (final channel in channels)
    if (_isRead(_indicatorOf(channel, overrides))) channel.id,
};

bool _isRead(UnreadIndicator indicator) =>
    !indicator.unread && !indicator.mentioned;

/// This container's own unread, live from its local store.
final accountUnreadProvider = StreamProvider<AccountUnread>((ref) async* {
  final store = await ref.watch(storeProvider.future);
  final overrides = ref.watch(channelNotificationOverridesProvider);
  yield* store.watchRailChannels().map((c) => countUnread(c, overrides));
});

/// This container's channels the rail shows as read.
final readChannelIdsProvider = StreamProvider<Set<String>>((ref) async* {
  final store = await ref.watch(storeProvider.future);
  final overrides = ref.watch(channelNotificationOverridesProvider);
  yield* store.watchRailChannels().map((c) => readChannelIds(c, overrides));
});
