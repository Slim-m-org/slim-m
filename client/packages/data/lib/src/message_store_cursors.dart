// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'message_store.dart';

/// The channel-cursor reads and the op-cursor write behind [MessageStore],
/// split out of `message_store.dart` to stay under the file budget. Private
/// top-level functions, like `message_store_batch.dart`, so the public methods
/// stay real methods on the type.
Future<Channel?> _channelRow(MessageStore store, String channelId) =>
    (store.db.select(store.db.channels)..where((c) => c.id.equals(channelId)))
        .getSingleOrNull();

Future<int?> _cursorFor(MessageStore store, String channelId) async =>
    (await _channelRow(store, channelId))?.cursor;

Future<int?> _opCursorFor(MessageStore store, String channelId) async =>
    (await _channelRow(store, channelId))?.opCursor;

Future<void> _setOpCursor(
    MessageStore store, String channelId, int? seq) async {
  final db = store.db;
  await db.transaction(() async {
    final row = await _channelRow(store, channelId);
    if (row == null) return;
    if (seq != null && row.opCursor != null && row.opCursor! >= seq) return;
    await (db.update(db.channels)..where((c) => c.id.equals(channelId)))
        .write(ChannelsCompanion(opCursor: Value(seq)));
  });
}
