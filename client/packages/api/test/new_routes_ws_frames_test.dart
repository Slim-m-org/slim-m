// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The WebSocket server frames this package picked up alongside the new REST
/// routes: decoding each `ServerEvent` from its wire JSON. Split from
/// `new_routes_test.dart` for the line budget; it shares none of that file's
/// REST helpers, only `ServerEvent.parse` and the models.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  group('new WebSocket frames', () {
    test('message.deleted decodes to MessageDeleted', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'message.deleted',
        'channel_id': 'c',
        'message_id': 'm',
      }));
      expect(event, isA<MessageDeleted>());
      expect((event! as MessageDeleted).channelId, 'c');
      expect((event as MessageDeleted).messageId, 'm');
    });

    test('reactions.changed decodes public tallies without a reacted flag', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'reactions.changed',
        'channel_id': 'c',
        'message_id': 'm',
        'reactions': [
          {'emoji': '\u{1F44D}', 'count': 2},
        ],
      }));
      expect(event, isA<ReactionsChanged>());
      final changed = event! as ReactionsChanged;
      expect(changed.reactions.single.emoji, '\u{1F44D}');
      expect(changed.reactions.single.count, 2);
    });

    test('message.pinned and message.unpinned decode', () {
      final pinned = ServerEvent.parse(jsonEncode({
        'type': 'message.pinned',
        'channel_id': 'c',
        'message_id': 'm',
        'pinned_by': 'u',
        'pinned_at': 42,
      }));
      expect(pinned, isA<MessagePinned>());
      expect((pinned! as MessagePinned).pinnedAt, 42);

      final unpinned = ServerEvent.parse(jsonEncode({
        'type': 'message.unpinned',
        'channel_id': 'c',
        'message_id': 'm',
      }));
      expect(unpinned, isA<MessageUnpinned>());
    });

    test('poll.voted decodes the refreshed tally, position and votes only', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'poll.voted',
        'channel_id': 'c',
        'message_id': 'm',
        'options': [
          {'position': 0, 'votes': 4},
          {'position': 1, 'votes': 1},
        ],
      }));
      expect(event, isA<PollVoted>());
      final voted = event! as PollVoted;
      expect(voted.options.map((o) => o.votes), [4, 1]);
    });

    test('a ranked poll.voted carries its runoff, and a ranked poll reads back',
        () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'poll.voted',
        'channel_id': 'c',
        'message_id': 'm',
        'options': [
          {'position': 0, 'votes': 2},
          {'position': 1, 'votes': 1},
        ],
        'runoff': {
          'rounds': [
            [
              {'position': 0, 'votes': 2},
              {'position': 1, 'votes': 1},
            ],
          ],
          'winner': 0,
        },
      }))! as PollVoted;
      expect(event.runoff?.rounds.single, {0: 2, 1: 1});
      expect(event.runoff?.winner, 0);

      final poll = Poll.fromJson({
        'question': 'q',
        'options': [
          {'position': 0, 'label': 'a', 'votes': 1},
          {'position': 1, 'label': 'b', 'votes': 0},
        ],
        'total_votes': 1,
        'voted_option': 0,
        'close_at': null,
        'closed': false,
        'ranked': true,
        'voted_ranking': [0, 1],
        'runoff': {'rounds': <Object>[], 'winner': null},
      });
      expect(poll.ranked, isTrue);
      expect(poll.votedRanking, [0, 1]);
      expect(poll.runoff?.rounds, isEmpty);
      final older = Poll.fromJson({
        'question': 'q',
        'options': <Object>[],
        'total_votes': 0,
        'closed': false,
      });
      expect(older.ranked, isFalse,
          reason: 'a server older than ranked polls omits it');
    });

    test('presence.changed decodes a known status', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'presence.changed',
        'user_id': 'u',
        'status': 'dnd',
      }));
      expect(event, isA<PresenceChanged>());
      expect((event! as PresenceChanged).status, PresenceState.dnd);
    });

    test(
        'presence.changed with an unrecognized status is ignored rather '
        'than throwing', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'presence.changed',
        'user_id': 'u',
        'status': 'quantum',
      }));
      expect(event, isNull);
    });

    test('typing.started and typing.stopped decode', () {
      final started = ServerEvent.parse(jsonEncode({
        'type': 'typing.started',
        'channel_id': 'c',
        'user_id': 'u',
      }));
      expect(started, isA<TypingStarted>());

      final stopped = ServerEvent.parse(jsonEncode({
        'type': 'typing.stopped',
        'channel_id': 'c',
        'user_id': 'u',
      }));
      expect(stopped, isA<TypingStopped>());
    });

    test('an unknown frame type is ignored, not fatal', () {
      expect(
        ServerEvent.parse(jsonEncode({'type': 'attachment.uploaded'})),
        isNull,
      );
    });

    test('a known type with the wrong shape is ignored, not a crash', () {
      // message.pinned missing pinned_at entirely.
      expect(
        ServerEvent.parse(jsonEncode({
          'type': 'message.pinned',
          'channel_id': 'c',
          'message_id': 'm',
        })),
        isNull,
      );
    });
  });
}
