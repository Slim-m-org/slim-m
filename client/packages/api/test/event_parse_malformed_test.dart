// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A known durable frame type with a body that does not parse asks for a
/// resync instead of throwing out of the socket's data callback; a malformed
/// ephemeral frame is ignored, like an unknown type.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  final malformed = <String, Map<String, Object?>>{
    'message.created with an empty message': {
      'type': 'message.created',
      'message': <String, Object?>{},
    },
    'reactions.changed with a non-map tally': {
      'type': 'reactions.changed',
      'channel_id': 'c',
      'message_id': 'm',
      'reactions': [1],
    },
    'message.deleted with a float op_seq': {
      'type': 'message.deleted',
      'channel_id': 'c',
      'message_id': 'm',
      'op_seq': 1.5,
    },
    'poll.voted without its options': {
      'type': 'poll.voted',
      'channel_id': 'c',
      'message_id': 'm',
    },
  };

  malformed.forEach((name, frame) {
    test('$name asks for a resync', () {
      final event = ServerEvent.parse(jsonEncode(frame));
      expect(event, isA<ErrorEvent>());
      expect((event! as ErrorEvent).needsResync, isTrue);
    });
  });

  test('a malformed ephemeral frame is ignored', () {
    final frame = {'type': 'typing.started', 'channel_id': 1};
    expect(ServerEvent.parse(jsonEncode(frame)), isNull);
  });

  test('an unknown frame type is ignored', () {
    final frame = {'type': 'message.from_the_future', 'x': 1};
    expect(ServerEvent.parse(jsonEncode(frame)), isNull);
  });

  test('a well-formed frame still parses', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'message.deleted',
        'channel_id': 'c',
        'message_id': 'm',
        'op_seq': 3,
      }),
    );
    expect(event, isA<MessageDeleted>());
  });
}
