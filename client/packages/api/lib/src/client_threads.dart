// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'models.dart';
import 'client.dart';
import 'client_transport.dart';

/// Opening a thread: the one call `openThread` needs, split out of
/// `client_messages.dart` to keep that file under the review budget, the
/// same reason `client_channel_admin.dart` exists.
extension SlimmApiThreads on SlimmApi {
  /// Opens (or reuses) the thread hanging off a message. Idempotent per
  /// message: a second call for the same message, by anyone who can already
  /// see it, returns the same channel. Requires VIEW_CHANNEL and
  /// SEND_MESSAGES in [channelId], the same bits [SlimmApiMessages.sendMessage]
  /// itself needs there - starting a thread is a way of sending, not a way
  /// of managing the channel. Refused if [messageId] is itself inside a
  /// thread; nesting is not supported.
  Future<Channel> openThread({
    required String channelId,
    required String messageId,
  }) async {
    final json = await send(
      'POST',
      '/channels/$channelId/messages/$messageId/thread',
    );
    return Channel.fromJson(json as Map<String, dynamic>);
  }

  /// What [channelId] is a thread's own channel hangs off, if it is one -
  /// the lookup a thread panel opened cold (a deep link, a reload, or a
  /// notification) needs, since none of those ever went through
  /// [openThread] on this device and so never learned the parent any other
  /// way. Masked to all-null exactly like [SlimmApiChannelAdmin
  /// .getChannelPermissions], so this can never be used to probe whether an
  /// unviewable channel exists. See docs/decisions/0011-per-channel-permissions.md.
  Future<ThreadParent> getThreadParent(String channelId) async {
    final json = await send('GET', '/channels/$channelId/thread-parent');
    return ThreadParent.fromJson(json as Map<String, dynamic>);
  }

  /// Every live thread hanging off a message in [channelId], newest activity
  /// first. Requires only VIEW_CHANNEL there, checked once: a thread's own
  /// visibility always resolves to its parent's, so this cannot be reached
  /// for a channel the caller cannot already view.
  Future<List<ThreadListItem>> listThreads(String channelId) async {
    final json = await send('GET', '/channels/$channelId/threads');
    return (json as List<dynamic>)
        .map((row) => ThreadListItem.fromJson(row as Map<String, dynamic>))
        .toList(growable: false);
  }
}
