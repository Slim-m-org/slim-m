// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `canOpenThreadFor`: gated like a reply, plus refused inside a thread
/// already, since nesting is refused server-side too. `canForwardMessage`:
/// the same pending/failed gate, deliberately with no permission check
/// against the message's own channel.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_data/data.dart';

Message _message({
  bool pending = false,
  bool failed = false,
  String? authorId,
}) => Message(
  id: 'm1',
  channelId: 'c1',
  authorId: authorId,
  seq: 1,
  content: 'hello',
  createdAt: 0,
  pending: pending,
  failed: failed,
);

void main() {
  test('offered with send permission, outside a thread', () {
    expect(
      canOpenThreadFor(_message(), Perm.sendMessages, channelIsThread: false),
      isTrue,
    );
  });

  test('refused without SEND_MESSAGES, matching the server\'s own gate', () {
    expect(canOpenThreadFor(_message(), 0, channelIsThread: false), isFalse);
  });

  test('refused inside a thread already, however the permissions read', () {
    expect(
      canOpenThreadFor(_message(), Perm.sendMessages, channelIsThread: true),
      isFalse,
      reason: 'nesting is refused server-side; this avoids a guaranteed 400',
    );
  });

  test('refused for a pending or failed send, matching canReplyToMessage', () {
    expect(
      canOpenThreadFor(
        _message(pending: true),
        Perm.sendMessages,
        channelIsThread: false,
      ),
      isFalse,
    );
    expect(
      canOpenThreadFor(
        _message(failed: true),
        Perm.sendMessages,
        channelIsThread: false,
      ),
      isFalse,
    );
  });

  test('a settled message, own or not, may be forwarded', () {
    expect(canForwardMessage(_message()), isTrue);
    expect(canForwardMessage(_message(authorId: 'someone-else')), isTrue);
  });

  test('a pending or failed send cannot be forwarded yet', () {
    expect(canForwardMessage(_message(pending: true)), isFalse);
    expect(canForwardMessage(_message(failed: true)), isFalse);
  });
}
