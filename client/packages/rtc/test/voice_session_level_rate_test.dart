// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How often a call reads the input gate: fast only while a meter is shown,
/// otherwise at the dead-mic watchdog rate.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'support/no_audio_devices.dart';

import 'support/session_fakes.dart';

class _FakeMic implements MicPort {
  bool published = false;
  bool muted = true;
  final enables = <(bool, lk.AudioCaptureOptions?)>[];
  final restarts = <bool>[];

  @override
  bool get hasTrack => published;

  double? senderLevel;

  @override
  Future<double?> senderLevelDb() async => senderLevel;

  @override
  Future<double?> capturedSeconds() async => null;

  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    enables.add((enabled, options));
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async =>
      restarts.add(options.noiseSuppression);

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}

  @override
  Stream<void> get lost => const Stream.empty();

  @override
  void onRoomEvent(lk.RoomEvent event) {}

  @override
  Future<void> discard() async => published = false;

  @override
  Future<void> release() async {}

  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {}
}

class _CountingGate {
  int polls = 0;

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'getInputGate') {
      polls++;
      return {'levelDb': -40.0, 'voice': false};
    }
    return null;
  }
}

const _tick = Duration(milliseconds: 2);

/// Polls land on the fake clock, so the counts are exact and no machine load can skew a ratio.
int _pollsIn(FakeAsync async, _CountingGate gate, Duration window) {
  final start = gate.polls;
  async.elapse(window);
  return gate.polls - start;
}

({_CountingGate gate, VoiceSession session}) _joinedSession(FakeAsync async) {
  final gate = _CountingGate();
  final session = VoiceSession(
    audioDevices: const NoAudioDevices(),
    roomFactory: ConnectlessRoom.new,
    micPort: _FakeMic(),
    inputGate: InputGateMonitor(
      interval: _tick,
      invoke: gate.invoke,
      supported: true,
    ),
  );
  unawaited(session.join(url: 'wss://a.invalid', token: 't'));
  async.flushMicrotasks();
  return (gate: gate, session: session);
}

const _window = Duration(milliseconds: 400);
const _settleAfterChange = Duration(milliseconds: 60);

void main() {
  test('a call with nothing displayed polls at a twentieth of the rate', () {
    fakeAsync((async) {
      final (:gate, :session) = _joinedSession(async);
      final watching = _pollsIn(async, gate, _window);
      session.setLevelDisplayed(true);
      final displayed = _pollsIn(async, gate, _window);
      expect(watching, lessThan(displayed ~/ 4));
      expect(watching, greaterThan(0), reason: 'the watchdog still reads');
      session.dispose();
    });
  });

  test('polling drops back when the meter goes away', () {
    fakeAsync((async) {
      final (:gate, :session) = _joinedSession(async);
      session.setLevelDisplayed(true);
      final displayed = _pollsIn(async, gate, _window);
      session.setLevelDisplayed(false);
      async.elapse(_settleAfterChange);
      final after = _pollsIn(async, gate, _window);
      expect(after, lessThan(displayed ~/ 4));
      session.dispose();
    });
  });

  test('automatic sensitivity adapts at a fifth of the display rate', () {
    fakeAsync((async) {
      final (:gate, :session) = _joinedSession(async);
      session.setLevelDisplayed(true);
      final displayed = _pollsIn(async, gate, _window);
      session.setLevelDisplayed(false);
      session.setAutoInputThreshold(true);
      async.elapse(_settleAfterChange);
      final adapting = _pollsIn(async, gate, _window);
      expect(adapting, lessThan(displayed ~/ 2));
      expect(adapting, greaterThan(displayed ~/ 10));
      session.dispose();
    });
  });
}
