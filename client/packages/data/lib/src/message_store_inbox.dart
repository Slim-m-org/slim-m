// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// Reads the inbox needs on top of the transcript queries.
extension MessageStoreInbox on MessageStore {
  /// The delivered message at [seq] in [channelId], or null when this client
  /// does not hold it.
  Future<Message?> messageAtSeq(String channelId, int seq) async {
    final row = await (db.select(db.messages)
          ..where((m) => m.channelId.equals(channelId) & m.seq.equals(seq)))
        .getSingleOrNull();
    return row?.toDto();
  }
}
