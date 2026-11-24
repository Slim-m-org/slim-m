// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'logging/app_log.dart';
import 'models.dart';

/// A page of messages as the server sent it.
///
/// [messages] omits any item this build cannot read, so only [rawCount] and
/// [minRawSeq] say whether the page was full and where the next one starts.
class MessagePage {
  const MessagePage({
    required this.messages,
    required this.rawCount,
    required this.minRawSeq,
  });

  final List<Message> messages;
  final int rawCount;
  final int? minRawSeq;

  /// True when the server sent fewer than [limit] items: the only proof of the start.
  bool isShort(int limit) => rawCount < limit;
}

/// Parses a page of messages, skipping one this build cannot read so the
/// rest of the page still loads.
MessagePage parseMessagePage(List<dynamic> raw) {
  final messages = <Message>[];
  int? minRawSeq;
  for (final item in raw) {
    if (item is Map<String, dynamic>) {
      final seq = item['seq'];
      if (seq is int && (minRawSeq == null || seq < minRawSeq)) {
        minRawSeq = seq;
      }
    }
    try {
      messages.add(Message.fromJson(item as Map<String, dynamic>));
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.sync,
        'Skipped a message this build cannot read',
        error,
        stack,
      );
    }
  }
  return MessagePage(
    messages: messages,
    rawCount: raw.length,
    minRawSeq: minRawSeq,
  );
}
