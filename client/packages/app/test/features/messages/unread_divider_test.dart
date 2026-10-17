// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The "new messages" divider marks where this account stopped reading, so a
/// message this account wrote can never be under it.
///
/// Without that, sending flashed the divider above your own message for the
/// instant between the optimistic insert and the read marker catching up:
/// the message really was newer than the last thing the account had read,
/// which is true and useless.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_dividers.dart';
import 'package:slimm_data/data.dart';

Message _msg({required String id, required int seq, required String? author}) =>
    Message(
      id: id,
      channelId: 'c1',
      authorId: author,
      authorDisplayName: 'Someone',
      seq: seq,
      content: 'hello',
      createdAt: 1700000000000,
      pending: false,
      failed: false,
    );

void main() {
  const me = 'user-me';
  const them = 'user-them';

  test('a message I just sent never starts an unread run', () {
    // seq 6 against a marker at 5 is the moment just after an optimistic send.
    final mine = _msg(id: 'm2', seq: 6, author: me);
    final read = _msg(id: 'm1', seq: 5, author: them);

    expect(startsUnread(mine, read, 5, me), isFalse);
  });

  test('someone else writing under the marker still starts one', () {
    final theirs = _msg(id: 'm2', seq: 6, author: them);
    final read = _msg(id: 'm1', seq: 5, author: them);

    expect(startsUnread(theirs, read, 5, me), isTrue);
  });

  test('with no session nothing is mine, so the divider behaves as before', () {
    final any = _msg(id: 'm2', seq: 6, author: them);

    expect(startsUnread(any, null, 5, null), isTrue);
  });

  test('an anonymised author is not mistaken for me', () {
    // A plain `authorId != selfId` calls two nulls a match, hiding it.
    final anonymous = _msg(id: 'm2', seq: 6, author: null);

    expect(startsUnread(anonymous, null, 5, null), isTrue);
  });
}
