// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'message_store.dart';

/// Whether the local store holds any message written by [authorId].
///
/// A top-level function for the reason [failInterruptedSends] is one: the
/// store class sits at its file ceiling.
Future<bool> hasMessageFrom(MessageStore store, String authorId) async {
  final query = store.db.select(store.db.messages)
    ..where((m) => m.authorId.equals(authorId))
    ..limit(1);
  return (await query.get()).isNotEmpty;
}

/// Whether the local store holds a message written by [authorId] in [channelId].
Future<bool> hasMessageFromIn(
  MessageStore store,
  String channelId,
  String authorId,
) async {
  final query = store.db.select(store.db.messages)
    ..where((m) => m.authorId.equals(authorId))
    ..where((m) => m.channelId.equals(channelId))
    ..limit(1);
  return (await query.get()).isNotEmpty;
}
