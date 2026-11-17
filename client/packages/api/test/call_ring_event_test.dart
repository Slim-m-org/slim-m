// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Frame-parsing coverage for `call.ringing` and `call.ring_ended`: the live
/// signal that lets a DM's callee see an incoming call, and both sides learn
/// how it ended.
library;

import 'dart:convert';

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

void main() {
  test('call.ringing decodes the channel, ring and caller ids', () {
    final event = ServerEvent.parse(jsonEncode({
      'type': 'call.ringing',
      'channel_id': 'c1',
      'ring_id': 'r1',
      'caller_id': 'u1',
    }));
    expect(event, isA<CallRinging>());
    final ringing = event! as CallRinging;
    expect(ringing.channelId, 'c1');
    expect(ringing.ringId, 'r1');
    expect(ringing.callerId, 'u1');
  });

  test('a call.ringing frame missing any field is ignored, not a crash', () {
    expect(
      ServerEvent.parse(
          jsonEncode({'type': 'call.ringing', 'channel_id': 'c1'})),
      isNull,
    );
  });

  for (final entry in {
    'answered': CallOutcome.answered,
    'declined': CallOutcome.declined,
    'canceled': CallOutcome.canceled,
    'timed_out': CallOutcome.timedOut,
  }.entries) {
    test('call.ring_ended decodes the "${entry.key}" outcome', () {
      final event = ServerEvent.parse(jsonEncode({
        'type': 'call.ring_ended',
        'channel_id': 'c1',
        'ring_id': 'r1',
        'outcome': entry.key,
      }));
      expect(event, isA<CallRingEnded>());
      final ended = event! as CallRingEnded;
      expect(ended.channelId, 'c1');
      expect(ended.ringId, 'r1');
      expect(ended.outcome, entry.value);
    });
  }

  test('an unrecognized outcome is ignored rather than guessed', () {
    expect(
      ServerEvent.parse(jsonEncode({
        'type': 'call.ring_ended',
        'channel_id': 'c1',
        'ring_id': 'r1',
        'outcome': 'exploded',
      })),
      isNull,
    );
  });

  test('a ring response lists who is on Do not disturb', () {
    final started = RingStarted.fromJson({
      'ring_id': 'r1',
      'timeout_ms': 0,
      'do_not_disturb': ['u2'],
    });
    expect(started.doNotDisturb, ['u2']);
    expect(started.timeoutMs, 0);
  });

  test('a ring response from an older server has nobody on Do not disturb', () {
    final started =
        RingStarted.fromJson({'ring_id': 'r1', 'timeout_ms': 30000});
    expect(started.doNotDisturb, isEmpty);
  });
}
