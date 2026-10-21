// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When a channel's newest message was sent, so a row menu only offers
/// "Mark as unread" where there is something recent to come back to.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_data/data.dart';

import '../../../providers/providers.dart';

/// How recent the newest message must be for "Mark as unread" to be offered.
const markUnreadWindow = Duration(hours: 1);

final markUnreadClockProvider = Provider<DateTime Function()>(
  (_) => DateTime.now,
);

/// Every channel's newest held seq from one watch on the small channels table, so a transcript write never re-runs a query per visible row.
/// Not autoDispose: rows remount constantly and share this one watch.
final channelCursorsProvider = StreamProvider<Map<String, int>>((ref) {
  // Watched rather than awaited: an async gap here deadlocks a widget test's teardown, see channelByIdProvider.
  final store = ref.watch(storeProvider).valueOrNull;
  if (store == null) return const Stream.empty();
  return store.watchChannelCursors();
});

/// One channel's newest held seq, notifying only when that channel's own
/// cursor moves. The rail's channel list drops cursor-only changes, so its
/// rows' `cursor` goes stale while a channel stays unread.
final channelNewestSeqProvider = Provider.autoDispose.family<int, String>(
  (ref, channelId) => ref.watch(
    channelCursorsProvider.select((a) => a.valueOrNull?[channelId] ?? 0),
  ),
);

/// The send time (ms since epoch) of [channelId]'s newest message, or null
/// when this client holds none.
final channelLatestMessageAtProvider = FutureProvider.autoDispose
    .family<int?, String>((ref, channelId) async {
      final seq = ref.watch(channelNewestSeqProvider(channelId));
      if (seq <= 0) return null;
      final store = await ref.watch(storeProvider.future);
      return (await store.messageAtSeq(channelId, seq))?.createdAt;
    });

/// Whether a message sent at [latestAt] is recent enough to mark unread.
bool offersMarkUnread(int? latestAt, DateTime now) =>
    latestAt != null &&
    now.difference(DateTime.fromMillisecondsSinceEpoch(latestAt)) <
        markUnreadWindow;

/// Keeps [channelId]'s newest message time loaded so a row menu knows
/// synchronously whether Mark as unread applies. It listens rather than
/// watches, so a new message rebuilds neither this nor the row beneath it.
class KeepsLatestMessageLoaded extends ConsumerWidget {
  const KeepsLatestMessageLoaded({
    super.key,
    required this.channelId,
    required this.child,
  });

  final String channelId;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    ref.listen(channelLatestMessageAtProvider(channelId), (_, _) {});
    return child;
  }
}
