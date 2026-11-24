// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which messages are a bot's re-post of a member this viewer blocked.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../members/providers/blocks_controller.dart';
import 'message_extras.dart';

/// Message ids, compared by content so a watcher rebuilds only when the set changes.
@immutable
class MessageIdSet {
  const MessageIdSet(this.ids);

  final Set<String> ids;

  static const empty = MessageIdSet({});

  bool contains(String messageId) => ids.contains(messageId);

  @override
  bool operator ==(Object other) =>
      other is MessageIdSet && setEquals(ids, other.ids);

  @override
  int get hashCode => Object.hashAllUnordered(ids);
}

/// The held messages that re-post a blocked member, hidden like that member's own.
final blockedRepostIdsProvider = Provider<MessageIdSet>((ref) {
  final blocked = ref.watch(blocksProvider.select((state) => state.ids));
  if (blocked.isEmpty) return MessageIdSet.empty;
  return ref.watch(
    messageExtrasProvider.select(
      (extras) => MessageIdSet({
        for (final entry in extras.entries)
          if (blocked.contains(entry.value.repostOfAuthorId)) entry.key,
      }),
    ),
  );
});
