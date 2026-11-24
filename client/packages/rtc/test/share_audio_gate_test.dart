// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A blocked share's audio is unsubscribed once per request, not on every room event.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/share_audio_gate.dart';

void main() {
  late List<String> calls;
  late List<Object> errors;
  late ShareAudioGate gate;

  void apply(
      {required bool blocked, required bool subscribed, Future<void>? answer}) {
    gate.apply(
      sid: 'TR_1',
      blocked: blocked,
      subscribed: subscribed,
      subscribe: () {
        calls.add('subscribe');
        return answer ?? Future.value();
      },
      unsubscribe: () {
        calls.add('unsubscribe');
        return answer ?? Future.value();
      },
    );
  }

  setUp(() {
    calls = [];
    errors = [];
    gate = ShareAudioGate(onError: errors.add);
  });

  test('refreshes while the first request is in flight send it once', () {
    for (var i = 0; i < 5; i++) {
      apply(blocked: true, subscribed: true);
    }
    expect(calls, ['unsubscribe']);
  });

  test('the same holds when subscribing again', () {
    for (var i = 0; i < 5; i++) {
      apply(blocked: false, subscribed: false);
    }
    expect(calls, ['subscribe']);
  });

  test('a state that settled and then flipped back is requested again', () {
    apply(blocked: true, subscribed: true);
    apply(blocked: true, subscribed: false);
    apply(blocked: false, subscribed: false);
    expect(calls, ['unsubscribe', 'subscribe']);
  });

  test('a failed request is retried on the next refresh', () async {
    final failure = Future<void>.error(StateError('socket closed'));
    apply(blocked: true, subscribed: true, answer: failure);
    await pumpEventQueue();
    apply(blocked: true, subscribed: true);
    expect(calls, ['unsubscribe', 'unsubscribe']);
    expect(errors, hasLength(1));
  });
}
