// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:convert';

import 'package:drift/drift.dart';

/// The uploaded attachment ids a queued send carries, keyed by its message id.
///
/// A side table rather than a column on `messages`: a field on the message row
/// is a field every query that reads one has to carry, and only a send that has
/// not landed yet ever has a value. A retry reads it back, so a message that
/// failed after its upload succeeded goes out again with its files instead of
/// as bare text.
///
/// Rows end with the send: swept when the store opens once the message landed
/// or was discarded, and wiped on sign-out with everything else.
@DataClassName('PendingAttachmentRow')
class PendingAttachments extends Table {
  TextColumn get messageId => text()();

  /// The ids in the order they were staged, stored as a JSON array.
  TextColumn get attachmentIds => text().map(const AttachmentIdList())();

  @override
  Set<Column> get primaryKey => {messageId};
}

/// Reads and writes an id list as the JSON array the column stores.
class AttachmentIdList extends TypeConverter<List<String>, String> {
  const AttachmentIdList();

  @override
  List<String> fromSql(String fromDb) =>
      (jsonDecode(fromDb) as List).cast<String>();

  @override
  String toSql(List<String> value) => jsonEncode(value);
}
