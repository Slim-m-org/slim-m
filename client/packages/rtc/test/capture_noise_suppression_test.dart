// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong turns libwebrtc's noise suppression off at capture, falls back to it
/// when rnnoise is not running, and only reopens the mic when that is safe.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _Harness {
  _Harness({bool supported = true, this.restartGate}) {
    capture = CaptureNoiseSuppression(
      supported: supported,
      restart: ({required webrtcNoiseSuppression}) async {
        restarts.add(webrtcNoiseSuppression);
        if (failures > 0) {
          failures--;
          throw StateError('room is reconnecting');
        }
        await restartGate?.future;
      },
      canRestart: () => canRestart,
      onNativeStrongChanged: () => nativeChanges++,
    );
  }

  late final CaptureNoiseSuppression capture;
  final restarts = <bool>[];
  final Completer<void>? restartGate;
  int failures = 0;
  bool canRestart = true;
  int nativeChanges = 0;

  void readings(int count, {required bool active, bool micOpen = true}) {
    for (var i = 0; i < count; i++) {
      capture.onReading(strongActive: active, micOpen: micOpen);
    }
  }
}

final _settle = kCaptureRestartDebounce * 2;

void main() {
  _moreTests();
  test('capture options follow the choice, and only where Strong can run', () {
    final h = _Harness();
    expect(h.capture.webrtcNoiseSuppression, isTrue);
    h.capture.setStrong(true);
    expect(h.capture.webrtcNoiseSuppression, isFalse);
    h.capture.setStrong(false);
    expect(h.capture.webrtcNoiseSuppression, isTrue);

    final unsupported = _Harness(supported: false)..capture.setStrong(true);
    expect(unsupported.capture.webrtcNoiseSuppression, isTrue);
  });

  test('capture options turn only noise suppression off', () {
    final switching = AudioDeviceSwitching(const _NoDevices());
    final off = switching.captureOptions(noiseSuppression: false);
    expect(off.noiseSuppression, isFalse);
    expect(off.echoCancellation, isTrue);
    expect(off.autoGainControl, isTrue);
    expect(off.stopAudioCaptureOnMute, isFalse);
    expect(switching.captureOptions().noiseSuppression, isTrue);
  });

  test('switching to Strong mid-call restarts the mic once, after a pause', () {
    fakeAsync((async) {
      final h = _Harness()..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      expect(h.restarts, isEmpty, reason: 'debounced');
      async.elapse(_settle);
      expect(h.restarts, [false]);
    });
  });

  test('rapid toggles collapse to one restart, or none when they cancel', () {
    fakeAsync((async) {
      final h = _Harness()..capture.opened(webrtcNoiseSuppression: true);
      h.capture
        ..setStrong(true)
        ..setStrong(false)
        ..setStrong(true);
      async.elapse(_settle);
      expect(h.restarts, [false]);

      final back = _Harness()..capture.opened(webrtcNoiseSuppression: true);
      back.capture
        ..setStrong(true)
        ..setStrong(false);
      async.elapse(_settle);
      expect(back.restarts, isEmpty);
    });
  });

  test('Strong stays on natively until libwebrtc is back after Standard', () {
    fakeAsync((async) {
      final h = _Harness()
        ..capture.setStrong(true)
        ..capture.opened(webrtcNoiseSuppression: false);
      h.capture.setStrong(false);
      expect(h.capture.nativeStrong, isTrue);
      async.elapse(_settle);
      expect(h.restarts, [true]);
      expect(h.capture.nativeStrong, isFalse);
    });
  });

  test('no restart while muted or on push-to-talk, then one once it is safe',
      () {
    fakeAsync((async) {
      final h = _Harness()
        ..canRestart = false
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(_settle);
      expect(h.restarts, isEmpty);

      h.canRestart = true;
      h.capture.retry();
      async.elapse(_settle);
      expect(h.restarts, [false]);
    });
  });

  test('at least one suppressor is always wanted, through every transition',
      () {
    fakeAsync((async) {
      final h = _Harness()..capture.opened(webrtcNoiseSuppression: true);
      void check() => expect(
            h.capture.webrtcNoiseSuppression || h.capture.nativeStrong,
            isTrue,
          );
      for (final step in <void Function()>[
        () => h.capture.setStrong(true),
        () => h.capture.opened(webrtcNoiseSuppression: false),
        () => h.readings(kStrongInactivePolls, active: false),
        () => h.capture.opened(webrtcNoiseSuppression: true),
        () => h.capture.setStrong(false),
        () => h.capture.setStrong(true),
        () => h.capture.fallBack(),
        () => h.capture.deviceChanged(),
        () => h.capture.reset(),
      ]) {
        step();
        check();
        async.elapse(_settle);
        check();
      }
    });
  });

  test('sustained inactive readings put libwebrtc suppression back', () {
    fakeAsync((async) {
      final h = _Harness()..capture.setStrong(true);
      h.capture.opened(webrtcNoiseSuppression: false);
      h.readings(kStrongInactivePolls - 1, active: false);
      async.elapse(_settle);
      expect(h.restarts, isEmpty);

      h.readings(1, active: false);
      async.elapse(_settle);
      expect(h.restarts, [true]);
      expect(h.capture.webrtcNoiseSuppression, isTrue);

      h.readings(kStrongActivePolls, active: true);
      async.elapse(_settle);
      expect(h.restarts, [true], reason: 'it stays on for the call');
    });
  });

  test('readings while muted never trigger the fallback', () {
    fakeAsync((async) {
      final h = _Harness()..capture.setStrong(true);
      h.capture.opened(webrtcNoiseSuppression: false);
      h.readings(kStrongInactivePolls * 2, active: false, micOpen: false);
      async.elapse(_settle);
      expect(h.restarts, isEmpty);
      expect(h.capture.webrtcNoiseSuppression, isFalse);
    });
  });

  test('a new input device gives Strong another chance', () {
    fakeAsync((async) {
      final h = _Harness()..capture.setStrong(true);
      h.capture.opened(webrtcNoiseSuppression: false);
      h.readings(kStrongInactivePolls, active: false);
      async.elapse(_settle);
      expect(h.restarts, [true]);

      h.capture
        ..deviceChanged()
        ..retry();
      async.elapse(_settle);
      expect(h.restarts, [true, false]);
    });
  });

  test('a device change alone schedules nothing, so a switch reopens once', () {
    fakeAsync((async) {
      final h = _Harness()..capture.setStrong(true);
      h.capture.opened(webrtcNoiseSuppression: false);
      h.readings(kStrongInactivePolls, active: false);
      async.elapse(_settle);
      h.capture.deviceChanged();
      h.capture.opened(webrtcNoiseSuppression: false);
      h.capture.retry();
      async.elapse(_settle);
      expect(h.restarts, [true], reason: 'the switch itself reopened it');
    });
  });

  test('the fallback never applies where Strong is not the choice', () {
    fakeAsync((async) {
      final h = _Harness()..capture.opened(webrtcNoiseSuppression: true);
      h.readings(kStrongInactivePolls * 2, active: false);
      async.elapse(_settle);
      expect(h.restarts, isEmpty);
    });
  });
}

void _finishRestart(FakeAsync async, Completer<void> gate) {
  gate.complete();
  async.flushMicrotasks();
}

void _moreTests() {
  test('a change during a restart waits for it, then the latest choice wins',
      () {
    fakeAsync((async) {
      final gate = Completer<void>();
      final h = _Harness(restartGate: gate)
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(kCaptureRestartDebounce);
      expect(h.restarts, [false]);

      h.capture
        ..retry()
        ..setStrong(false);
      async.elapse(_settle);
      expect(h.restarts, [false], reason: 'no second concurrent restart');

      _finishRestart(async, gate);
      async.elapse(_settle);
      expect(h.restarts, [false, true], reason: 'Standard is applied after');
      expect(h.capture.nativeStrong, isFalse);
    });
  });

  test('a retry during a restart does not start a second one', () {
    fakeAsync((async) {
      final gate = Completer<void>();
      final h = _Harness(restartGate: gate)
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(kCaptureRestartDebounce);
      h.capture.retry();
      async.elapse(_settle);
      expect(h.restarts, [false]);
      _finishRestart(async, gate);
    });
  });

  test('a failed restart is retried with a growing wait', () {
    fakeAsync((async) {
      final h = _Harness()
        ..failures = 2
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(kCaptureRestartDebounce);
      expect(h.restarts.length, 1);
      async.elapse(kCaptureRestartDebounce * 2);
      expect(h.restarts.length, 2);
      async.elapse(kCaptureRestartDebounce * 4);
      expect(h.restarts, [false, false, false]);
      expect(h.capture.nativeStrong, isTrue);
      async.elapse(kMaxRestartBackoff);
      expect(h.restarts.length, 3, reason: 'settled once it worked');
    });
  });

  test('a retry waits out a room that is not connected', () {
    fakeAsync((async) {
      final h = _Harness()
        ..failures = 1
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(kCaptureRestartDebounce);
      h.canRestart = false;
      async.elapse(kCaptureRestartDebounce * 3);
      expect(h.restarts.length, 1);
      h.canRestart = true;
      async.elapse(kMaxRestartBackoff);
      expect(h.restarts, [false, false]);
    });
  });

  test('reset forgets the last call, fallback included', () {
    fakeAsync((async) {
      final h = _Harness()..capture.setStrong(true);
      h.capture.opened(webrtcNoiseSuppression: false);
      h.readings(kStrongInactivePolls, active: false);
      async.elapse(_settle);
      expect(h.capture.webrtcNoiseSuppression, isTrue);

      h.capture.reset();
      expect(h.capture.webrtcNoiseSuppression, isFalse);
      expect(h.capture.nativeStrong, isTrue, reason: 'still the choice');
    });
  });

  test('a restart finishing after dispose touches nothing', () {
    fakeAsync((async) {
      final gate = Completer<void>();
      final h = _Harness(restartGate: gate)
        ..capture.opened(webrtcNoiseSuppression: true);
      h.capture.setStrong(true);
      async.elapse(kCaptureRestartDebounce);
      final changes = h.nativeChanges;
      h.capture.dispose();
      _finishRestart(async, gate);
      expect(h.nativeChanges, changes);
    });
  });
}

class _NoDevices implements AudioDevices {
  const _NoDevices();

  @override
  Future<List<AudioDevice>> inputs() async => const [];

  @override
  Future<List<AudioDevice>> outputs() async => const [];

  @override
  Future<AudioDevice?> systemDefaultInput() async => null;

  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;

  @override
  Stream<void> get onChange => const Stream.empty();
}
