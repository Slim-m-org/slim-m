// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/src/video_stall_watchdog.dart';

class _Clock {
  DateTime now = DateTime(2026, 10, 16, 12);
  void advance(Duration by) => now = now.add(by);
}

VideoStallReading _playing(int frames, {String key = 'camera:bob'}) =>
    VideoStallReading(key: key, framesDecoded: frames, expectPlaying: true);

void main() {
  late _Clock clock;
  late List<(String, VideoStallStep)> steps;
  late VideoStallWatchdog watchdog;

  setUp(() {
    clock = _Clock();
    steps = [];
    watchdog = VideoStallWatchdog(
      recover: (key, step) => steps.add((key, step)),
      clock: () => clock.now,
    );
  });

  tearDown(() => watchdog.dispose());

  test('advancing frames are healthy and ask for nothing', () {
    for (var i = 0; i < 10; i++) {
      watchdog.observe([_playing(i * 30)]);
      clock.advance(const Duration(seconds: 2));
    }
    expect(steps, isEmpty);
    expect(watchdog.health.value, isEmpty);
  });

  test('frames standing still past the threshold switch the layer', () {
    watchdog.observe([_playing(100)]);
    clock.advance(const Duration(seconds: 2));
    watchdog.observe([_playing(100)]);
    expect(steps, isEmpty, reason: 'two seconds is not a stall yet');

    clock.advance(const Duration(seconds: 2));
    watchdog.observe([_playing(100)]);
    expect(steps, [('camera:bob', VideoStallStep.switchLayer)]);
    expect(watchdog.health.value, {'camera:bob': VideoTileHealth.stalled});
  });

  test('recovery steps run in order, then it gives up and says stopped', () {
    watchdog.observe([_playing(5)]);
    for (var i = 0; i < 10; i++) {
      clock.advance(const Duration(seconds: 2));
      watchdog.observe([_playing(5)]);
    }
    expect(steps.map((s) => s.$2), [
      VideoStallStep.switchLayer,
      VideoStallStep.resubscribe,
    ]);
    expect(watchdog.health.value, {'camera:bob': VideoTileHealth.stopped});
  });

  test('frames coming back clear the stall', () {
    watchdog.observe([_playing(50)]);
    clock.advance(const Duration(seconds: 4));
    watchdog.observe([_playing(50)]);
    expect(watchdog.health.value, isNotEmpty);

    clock.advance(const Duration(seconds: 2));
    watchdog.observe([_playing(80)]);
    expect(watchdog.health.value, isEmpty);
  });

  test('a muted, hidden or not-yet-owed video never stalls', () {
    const idle = VideoStallReading(
      key: 'camera:bob',
      framesDecoded: 7,
      expectPlaying: false,
    );
    watchdog.observe([idle]);
    for (var i = 0; i < 6; i++) {
      clock.advance(const Duration(seconds: 2));
      watchdog.observe([idle]);
    }
    expect(steps, isEmpty);
    expect(watchdog.health.value, isEmpty);
  });

  test('a server pause shows paused and asks for no recovery', () {
    const paused = VideoStallReading(
      key: 'screen:bob',
      framesDecoded: 9,
      expectPlaying: false,
      paused: true,
    );
    watchdog.observe([paused]);
    clock.advance(const Duration(seconds: 10));
    watchdog.observe([paused]);
    expect(steps, isEmpty);
    expect(watchdog.health.value, {'screen:bob': VideoTileHealth.paused});
  });

  test('a resubscribe that brings no frames back ends in stopped, once', () {
    watchdog.observe([_playing(500)]);
    clock.advance(const Duration(seconds: 4));
    watchdog.observe([_playing(500)]);
    clock.advance(const Duration(seconds: 4));
    watchdog.observe([_playing(500)]);
    expect(steps.last.$2, VideoStallStep.resubscribe);

    // The old receiver goes away, then a fresh one sits at zero.
    clock.advance(const Duration(seconds: 1));
    watchdog.observe([
      const VideoStallReading(
        key: 'camera:bob',
        framesDecoded: null,
        expectPlaying: false,
      ),
    ]);
    for (var i = 0; i < 8; i++) {
      clock.advance(const Duration(seconds: 2));
      watchdog.observe([_playing(0)]);
    }
    expect(steps.length, 2, reason: 'recovery must not start over');
    expect(watchdog.health.value, {'camera:bob': VideoTileHealth.stopped});
  });

  test('a fresh receiver that starts decoding clears the stall', () {
    watchdog.observe([_playing(500)]);
    for (var i = 0; i < 4; i++) {
      clock.advance(const Duration(seconds: 2));
      watchdog.observe([_playing(500)]);
    }
    watchdog.observe([_playing(0)]);
    expect(watchdog.health.value, {'camera:bob': VideoTileHealth.stalled});
    clock.advance(const Duration(seconds: 2));
    watchdog.observe([_playing(60)]);
    expect(watchdog.health.value, isEmpty);
  });

  test('a tile that disappears is forgotten', () {
    watchdog.observe([_playing(1)]);
    clock.advance(const Duration(seconds: 4));
    watchdog.observe([_playing(1)]);
    expect(watchdog.health.value, isNotEmpty);
    watchdog.observe(const []);
    expect(watchdog.health.value, isEmpty);
  });

  group('stallReadings', () {
    StallPublication pub({
      bool subscribed = true,
      bool muted = false,
      bool active = true,
    }) =>
        (
          key: 'camera:bob',
          subscribed: subscribed,
          muted: muted,
          active: active,
          framesDecoded: 1,
        );

    test('owes frames only when subscribed, unmuted, active and wanted', () {
      bool owes(StallPublication p, {Set<String>? interest}) => stallReadings(
            [p],
            interest: interest,
            seenActive: const {},
          ).single.expectPlaying;
      expect(owes(pub()), isTrue);
      expect(owes(pub(), interest: {'camera:bob'}), isTrue);
      expect(owes(pub(), interest: {'camera:alice'}), isFalse);
      expect(owes(pub(muted: true)), isFalse);
      expect(owes(pub(subscribed: false)), isFalse);
      expect(owes(pub(active: false)), isFalse);
    });

    test('a pause counts only after the stream was active once', () {
      final fresh = stallReadings(
        [pub(active: false)],
        interest: null,
        seenActive: const {},
      ).single;
      final later = stallReadings(
        [pub(active: false)],
        interest: null,
        seenActive: const {'camera:bob'},
      ).single;
      expect(fresh.paused, isFalse);
      expect(later.paused, isTrue);
    });
  });
}
