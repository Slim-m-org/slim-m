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

/// The send time (ms since epoch) of [channelId]'s newest message, or null
/// when this client holds none.
final channelLatestMessageAtProvider = StreamProvider.autoDispose
    .family<int?, String>((ref, channelId) async* {
      final store = await ref.watch(storeProvider.future);
      yield* store.watchNewestMessageAt(channelId);
    });

/// Whether a message sent at [latestAt] is recent enough to mark unread.
bool offersMarkUnread(int? latestAt, DateTime now) =>
    latestAt != null &&
    now.difference(DateTime.fromMillisecondsSinceEpoch(latestAt)) <
        markUnreadWindow;

/// Keeps [channelId]'s newest message time loaded so a row menu knows
/// synchronously whether Mark as unread applies, without the row watching it.
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
    ref.watch(channelLatestMessageAtProvider(channelId));
    return child;
  }
}
