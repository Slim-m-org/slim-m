// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Something to say about a few messages, such as a request the server
/// refused, held in one map so a message with nothing to say costs nothing.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Notes by message id. A message has an entry only while it has a note.
class MessageNotes<T> extends Notifier<Map<String, T>> {
  @override
  Map<String, T> build() => const {};

  /// Sets [messageId]'s note, or clears it when [note] is null.
  void put(String messageId, T? note) {
    if (note != null) {
      state = {...state, messageId: note};
    } else if (state.containsKey(messageId)) {
      state = {
        for (final entry in state.entries)
          if (entry.key != messageId) entry.key: entry.value,
      };
    }
  }
}
