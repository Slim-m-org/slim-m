// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [ServerEvent.parse] for `voice.moved`: a moderator moved this account.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('parses a well-formed voice.moved frame', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'voice.moved',
        'from_channel_id': 'a',
        'to_channel_id': 'b',
        'to_channel_name': 'games',
        'moved_by_id': 'u1',
        'moved_by_name': 'Alice',
      }),
    );
    final moved = event! as VoiceMoved;
    expect(moved.fromChannelId, 'a');
    expect(moved.toChannelId, 'b');
    expect(moved.toChannelName, 'games');
    expect(moved.movedByName, 'Alice');
  });

  test('a frame missing the destination is ignored', () {
    final event = ServerEvent.parse(
      jsonEncode({
        'type': 'voice.moved',
        'from_channel_id': 'a',
        'moved_by_id': 'u1',
        'moved_by_name': 'Alice',
      }),
    );
    expect(event, isNull);
  });
}
