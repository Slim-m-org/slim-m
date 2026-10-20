// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When a channel's newest message was sent, so a row menu only offers
/// "Mark as unread" where there is something recent to come back to.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';

/// How recent the newest message must be for "Mark as unread" to be offered.
const markUnreadWindow = Duration(hours: 1);

final markUnreadClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// The send time (ms since epoch) of the message at [seq], the channel's
/// cursor, or null when this client holds no such message.
final channelLatestMessageAtProvider = FutureProvider.autoDispose
    .family<int?, ({String channelId, int seq})>((ref, key) async {
      if (key.seq <= 0) return null;
      final store = await ref.watch(storeProvider.future);
      return (await store.messageAtSeq(key.channelId, key.seq))?.createdAt;
    });

/// Whether a message sent at [latestAt] is recent enough to mark unread.
bool offersMarkUnread(int? latestAt, DateTime now) =>
    latestAt != null &&
    now.difference(DateTime.fromMillisecondsSinceEpoch(latestAt)) <
        markUnreadWindow;
