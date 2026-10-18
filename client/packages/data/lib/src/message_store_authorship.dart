// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

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
