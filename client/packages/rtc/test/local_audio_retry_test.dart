// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed push is retried on its own schedule, whatever the room events do.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/fake_audio_track.dart';

const _delays = [
  Duration(milliseconds: 100),
  Duration(milliseconds: 400),
  Duration(seconds: 1),
];

void main() {
  late LocalAudioState state;
  late FakeAudioTrack track;
  late List<String> warnings;

  setUp(() {
    state = LocalAudioState(retryDelays: _delays);
    warnings = [];
    state.log = (message, {level = LogLevel.info}) {
      if (message.startsWith('Volume still failing')) warnings.add(message);
    };
    track = FakeAudioTrack('maya')..failure = Exception('no');
  });

  void applyAndFlush(FakeAsync async) {
    unawaited(state.applyToRefs([track.ref]));
    async.flushMicrotasks();
  }

  test('room events during a pending retry do not burn the attempts', () {
    fakeAsync((async) {
      applyAndFlush(async);
      for (var i = 0; i < 10; i++) {
        applyAndFlush(async);
        async.elapse(const Duration(milliseconds: 5));
      }
      expect(warnings, isEmpty, reason: 'ten events are not ten retries');

      async.elapse(const Duration(seconds: 2));
      expect(warnings, hasLength(1), reason: 'the three timed retries ran');
    });
  });

  test('after the cap it stops until the target changes', () {
    fakeAsync((async) {
      applyAndFlush(async);
      async.elapse(const Duration(seconds: 3));
      expect(warnings, hasLength(1));
      final calls = track.platformCalls;

      async.elapse(const Duration(seconds: 30));
      expect(track.platformCalls, calls, reason: 'no timer is left running');
      applyAndFlush(async);
      async.elapse(const Duration(seconds: 30));
      expect(warnings, hasLength(1), reason: 'the warning is not repeated');

      state.setVolumeFor('maya', 1.5);
      applyAndFlush(async);
      async.elapse(const Duration(seconds: 3));
      expect(warnings, hasLength(2), reason: 'a new target gets new retries');
    });
  });

  test('cancelRetry leaves no timer firing a pass', () {
    fakeAsync((async) {
      applyAndFlush(async);
      state.cancelRetry();
      final calls = track.platformCalls;
      async.elapse(const Duration(seconds: 3));
      expect(track.platformCalls, calls);
    });
  });

  group('a pass that throws', () {
    Iterable<LocalAudioRef> throwing() sync* {
      throw StateError('participant torn down');
    }

    test('completes the caller instead of leaving it hanging', () async {
      final state = LocalAudioState();
      final result = await state.applyToRefs(throwing()).timeout(
            const Duration(seconds: 1),
          );
      expect(result, isA<StateError>());
    });

    test('completes a queued waiter too', () async {
      final state = LocalAudioState();
      final first = state.applyToRefs(throwing());
      final second = state.applyToRefs(throwing());
      await Future.wait([first, second]).timeout(const Duration(seconds: 1));
    });
  });
}
