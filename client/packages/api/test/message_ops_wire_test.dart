// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests the message-op wire shapes, and in particular the three cases where
/// a missing field has to mean something specific rather than nothing.
///
/// A new client talking to an old server, an old client talking to a new one,
/// and a new kind arriving from a newer server than this one all have to be
/// distinguishable from "the stream is empty", because in each case doing
/// nothing quietly keeps a stale copy on screen.
library;

import 'package:test/test.dart';
import 'package:slimm_api/api.dart';

void main() {
  group('MessageOp', () {
    test('an edit carries its content and its edited stamp', () {
      final op = MessageOp.fromJson(const {
        'seq': 7,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1000,
        'content': 'revised',
        'edited_at': 2000,
      });

      expect(op, isA<MessageEditOp>());
      final edit = op as MessageEditOp;
      expect(edit.seq, 7);
      expect(edit.messageId, 'm1');
      expect(edit.content, 'revised');
      expect(edit.editedAt, 2000);
    });

    test('an edit whose message has since been deleted carries no content', () {
      // Joined at read time, so a later delete op is what the client acts on.
      final op = MessageOp.fromJson(const {
        'seq': 8,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1000,
      }) as MessageEditOp;

      expect(op.content, null);
      expect(op.seq, 8, reason: 'it keeps its seq, so the cursor advances');
    });

    test('a delete parses as its own kind', () {
      final op = MessageOp.fromJson(const {
        'seq': 9,
        'kind': 'delete',
        'message_id': 'm1',
        'created_at': 1000,
      });

      expect(op, isA<MessageDeleteOp>());
      expect(op.messageId, 'm1');
    });

    test('an unrecognised kind becomes a value rather than being dropped', () {
      // Dropping it advances no cursor, so the stale copy would simply stay.
      final op = MessageOp.fromJson(const {
        'seq': 10,
        'kind': 'redact',
        'message_id': 'm1',
        'created_at': 1000,
      });

      expect(op, isA<MessageUnknownOp>());
      expect(op.seq, 10);
      expect(op.messageId, 'm1');
    });
  });

  group('ScopeCursor', () {
    test('an op cursor is sent when held', () {
      const cursor = ScopeCursor(channelId: 'c1', afterSeq: 12, afterOpSeq: 5);

      expect(cursor.toJson(), {
        'channel_id': 'c1',
        'after_seq': 12,
        'after_op_seq': 5,
      });
    });

    test('no op cursor means the key is absent, not null', () {
      // Absent is what opts the scope out, and what an older client sends.
      const cursor = ScopeCursor(channelId: 'c1', afterSeq: 12);

      expect(cursor.toJson(), {'channel_id': 'c1', 'after_seq': 12});
    });
  });

  group('ScopeDelta', () {
    test('an old server is told apart from an empty stream', () {
      // No key at all means no op stream, not a stream nothing has written to.
      final delta = ScopeDelta.fromJson(const {
        'channel_id': 'c1',
        'messages': <dynamic>[],
        'has_more': false,
        'reset': false,
      });

      expect(delta.opLatestSeq, null);
      expect(delta.ops, isEmpty);
      expect(delta.opsHasMore, false);
    });

    test('a new server reporting an empty stream still names its head', () {
      final delta = ScopeDelta.fromJson(const {
        'channel_id': 'c1',
        'messages': <dynamic>[],
        'has_more': false,
        'reset': false,
        'ops': <dynamic>[],
        'op_latest_seq': 0,
        'ops_has_more': false,
      });

      expect(delta.opLatestSeq, 0, reason: 'zero is an answer, null is not');
      expect(delta.ops, isEmpty);
    });

    test('ops parse in order with their kinds', () {
      final delta = ScopeDelta.fromJson(const {
        'channel_id': 'c1',
        'messages': <dynamic>[],
        'has_more': false,
        'reset': false,
        'ops': [
          {
            'seq': 1,
            'kind': 'edit',
            'message_id': 'm1',
            'created_at': 1,
            'content': 'revised',
          },
          {'seq': 2, 'kind': 'delete', 'message_id': 'm2', 'created_at': 2},
        ],
        'op_latest_seq': 2,
        'ops_has_more': true,
      });

      expect(delta.ops.map((o) => o.seq), [1, 2]);
      expect(delta.ops.first, isA<MessageEditOp>());
      expect(delta.ops.last, isA<MessageDeleteOp>());
      expect(delta.opsHasMore, true);
    });
  });

  group('live frames', () {
    test('an edit frame carries an op seq distinct from the message seq', () {
      final event = ServerEvent.parse(
        '{"type":"message.edited","op_seq":9,"message":{'
        '"id":"m1","channel_id":"c1","author_id":"u1",'
        '"author_display_name":"Mara","seq":4,"content":"revised",'
        '"created_at":1000,"edited_at":2000}}',
      ) as MessageEdited;

      expect(event.opSeq, 9);
      expect(event.message.seq, 4,
          reason: 'an edit does not move the message seq');
    });

    test('an old server sends no op seq on either frame', () {
      final edited = ServerEvent.parse(
        '{"type":"message.edited","message":{'
        '"id":"m1","channel_id":"c1","author_id":"u1",'
        '"author_display_name":"Mara","seq":4,"content":"revised",'
        '"created_at":1000}}',
      ) as MessageEdited;
      final deleted = ServerEvent.parse(
        '{"type":"message.deleted","channel_id":"c1","message_id":"m1"}',
      ) as MessageDeleted;

      expect(edited.opSeq, null);
      expect(deleted.opSeq, null);
    });

    test('a delete frame carries its op seq', () {
      final event = ServerEvent.parse(
        '{"type":"message.deleted","channel_id":"c1","message_id":"m1",'
        '"op_seq":11}',
      ) as MessageDeleted;

      expect(event.opSeq, 11);
    });

    test('an edit op carries forwarded_removed, defaulting to false', () {
      final flagged = MessageOp.fromJson({
        'seq': 3,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1,
        'forwarded_removed': true,
      }) as MessageEditOp;
      final plain = MessageOp.fromJson({
        'seq': 4,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1,
      }) as MessageEditOp;

      expect(flagged.forwardedRemoved, isTrue);
      expect(plain.forwardedRemoved, isFalse);
    });

    test('an edit op carries link_previews_removed, defaulting to false', () {
      final flagged = MessageOp.fromJson({
        'seq': 3,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1,
        'link_previews_removed': true,
      }) as MessageEditOp;
      final plain = MessageOp.fromJson({
        'seq': 4,
        'kind': 'edit',
        'message_id': 'm1',
        'created_at': 1,
      }) as MessageEditOp;

      expect(flagged.linkPreviewsRemoved, isTrue);
      expect(plain.linkPreviewsRemoved, isFalse);
    });
  });
}
