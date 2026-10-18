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

  /// For each channel, the message the inbox shows: the one at its mention
  /// seq when given, else its newest delivered one. A channel this client holds
  /// nothing for is absent from the result.
  ///
  /// One query per [_inboxChunk] channels, not one per channel, since the inbox
  /// re-reads this on every channel update.
  Future<Map<String, Message>> inboxMessages(
    Map<String, int?> mentionSeqByChannel,
  ) async {
    final found = <String, Message>{};
    final ids = mentionSeqByChannel.keys.toList(growable: false);
    for (var i = 0; i < ids.length; i += _inboxChunk) {
      final chunk = ids.skip(i).take(_inboxChunk).toList(growable: false);
      final variables = <Variable>[];
      final clauses = <String>[];
      for (final id in chunk) {
        final seq = mentionSeqByChannel[id];
        variables.add(Variable<String>(id));
        if (seq == null) {
          clauses.add(
            '(m.channel_id = ? AND m.seq = '
            '(SELECT MAX(seq) FROM messages WHERE channel_id = m.channel_id))',
          );
        } else {
          clauses.add('(m.channel_id = ? AND m.seq = ?)');
          variables.add(Variable<int>(seq));
        }
      }
      final rows = await db.customSelect(
        'SELECT m.* FROM messages m WHERE ${clauses.join(' OR ')}',
        variables: variables,
        readsFrom: {db.messages},
      ).get();
      for (final row in rows) {
        final message = db.messages.map(row.data).toDto();
        found[message.channelId] = message;
      }
    }
    return found;
  }
}

const _inboxChunk = 300;
