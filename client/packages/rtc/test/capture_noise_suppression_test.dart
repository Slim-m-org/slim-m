// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong turns libwebrtc's noise suppression off at capture, falls back to it
/// when rnnoise is not running, and only reopens the mic when that is safe.
library;

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _Harness {
  _Harness({bool supported = true}) {
    capture = CaptureNoiseSuppression(
      supported: supported,
      restart: ({required webrtcNoiseSuppression}) async =>
          restarts.add(webrtcNoiseSuppression),
      canRestart: () => canRestart,
      onNativeStrongChanged: () => nativeChanges++,
    );
  }

  late final CaptureNoiseSuppression capture;
  final restarts = <bool>[];
  bool canRestart = true;
  int nativeChanges = 0;

  void readings(int count, {required bool active, bool micOpen = true}) {
    for (var i = 0; i < count; i++) {
      capture.onReading(strongActive: active, micOpen: micOpen);
    }
  }
}

const _settle = Duration(seconds: 2);

void main() {
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

      h.capture.deviceChanged();
      async.elapse(_settle);
      expect(h.restarts, [true, false]);
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
