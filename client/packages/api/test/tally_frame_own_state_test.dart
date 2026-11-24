// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The receiving user's own state and the version on `reactions.changed` and `poll.voted`.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('reactions.changed decodes each row\'s reacted flag and the version',
      () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'reactions.changed',
      'channel_id': 'c',
      'message_id': 'm',
      'reactions': [
        {'emoji': ':wave:', 'count': 2, 'reacted': true},
        {'emoji': ':tada:', 'count': 1, 'reacted': false},
      ],
      'version': 1700000000000001,
    }))! as ReactionsChanged;
    expect(event.reactions.map((r) => r.reacted), [true, false]);
    expect(event.version, 1700000000000001);
  });

  test('a reactions.changed from an older server leaves both unknown', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'reactions.changed',
      'channel_id': 'c',
      'message_id': 'm',
      'reactions': [
        {'emoji': ':wave:', 'count': 2},
      ],
    }))! as ReactionsChanged;
    expect(event.reactions.single.reacted, isNull);
    expect(event.version, isNull);
  });

  test('poll.voted decodes the own vote and version when present', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'poll.voted',
      'channel_id': 'c',
      'message_id': 'm',
      'options': [
        {'position': 0, 'votes': 1},
        {'position': 1, 'votes': 1},
      ],
      'version': 9,
      'voted_option': 1,
      'voted_ranking': [1, 0],
    }))! as PollVoted;
    expect(event.version, 9);
    expect(event.votedOption, 1);
    expect(event.votedRanking, [1, 0]);
  });

  test('another viewer\'s poll.voted carries no own vote', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'poll.voted',
      'channel_id': 'c',
      'message_id': 'm',
      'options': [
        {'position': 0, 'votes': 1},
      ],
      'version': 9,
    }))! as PollVoted;
    expect(event.votedOption, isNull);
    expect(event.votedRanking, isNull);
  });
}
