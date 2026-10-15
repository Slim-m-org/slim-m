// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A known frame type with a body that does not parse is ignored, like an
/// unknown type, instead of throwing out of the socket's data callback.
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
  };

  malformed.forEach((name, frame) {
    test('$name is ignored', () {
      expect(ServerEvent.parse(jsonEncode(frame)), isNull);
    });
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
