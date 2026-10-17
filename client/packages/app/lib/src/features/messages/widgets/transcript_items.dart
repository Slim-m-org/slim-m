// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the transcript lays out: stored messages with the viewer's private bot
/// answers set among them by arrival time. See
/// docs/decisions/0037-ephemeral-bot-messages.md.
library;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';

sealed class TranscriptItem {
  const TranscriptItem();

  String get id;
}

class StoredItem extends TranscriptItem {
  const StoredItem(this.message);

  final Message message;

  @override
  String get id => message.id;
}

class PrivateItem extends TranscriptItem {
  const PrivateItem(this.message);

  final api.EphemeralMessage message;

  @override
  String get id => message.id;
}

/// Each private answer lands after the last stored message at or before its time, so a reply sits right under its command.
List<TranscriptItem> mergePrivateAnswers(
  List<Message> messages,
  List<api.EphemeralMessage> answers,
) {
  if (answers.isEmpty) return [for (final m in messages) StoredItem(m)];
  final items = <TranscriptItem>[];
  var next = 0;
  final ordered = [...answers]..sort((a, b) => a.createdAt - b.createdAt);
  for (final message in messages) {
    while (next < ordered.length &&
        ordered[next].createdAt < message.createdAt) {
      items.add(PrivateItem(ordered[next++]));
    }
    items.add(StoredItem(message));
  }
  while (next < ordered.length) {
    items.add(PrivateItem(ordered[next++]));
  }
  return items;
}

Message? storedAt(List<TranscriptItem> items, int index) =>
    index < 0 || index >= items.length
    ? null
    : switch (items[index]) {
        StoredItem(:final message) => message,
        PrivateItem() => null,
      };

Message? storedAbove(List<TranscriptItem> items, int index) {
  for (var j = index - 1; j >= 0; j--) {
    if (storedAt(items, j) case final message?) return message;
  }
  return null;
}
