// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A capture whose sample counter stops is restarted even while Strong
/// suppression keeps the level watchdog quiet and the sender level reads stale.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  int restarts = 0;

  /// Seconds the capture reports; [ticking] moves it forward on every read.
  double captured = 0;
  bool ticking = true;
  bool readFails = false;

  @override
  bool get hasTrack => published;

  @override
  bool get open => published && !muted;

  @override
  Future<double?> senderLevelDb() async => -30;

  @override
  Future<double?> capturedSeconds() async {
    if (readFails) throw StateError('no stats');
    if (ticking) captured += 1.5;
    return captured;
  }

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    restarts++;
    ticking = healsOnRestart;
  }

  bool healsOnRestart = true;

  @override
  Future<void> release() async {}

  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {}

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}

  @override
  Stream<void> get lost => const Stream.empty();

  @override
  void onRoomEvent(lk.RoomEvent event) {}

  @override
  Future<void> discard() async => published = false;
}

class _Devices implements AudioDevices {
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

const _timing = MicRecoveryTiming(
  retryBase: Duration(milliseconds: 10),
  silence: Duration(seconds: 30),
  silentCooldown: Duration(milliseconds: 30),
  maxSilentRestarts: 2,
  recoveredAfter: Duration(seconds: 30),
  deviceDebounce: Duration(milliseconds: 20),
  captureProbe: Duration(milliseconds: 5),
  captureStall: Duration(milliseconds: 40),
);

class _Rig {
  _Rig() {
    session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      audioDevices: _Devices(),
      micRecoveryTiming: _timing,
      inputGate: InputGateMonitor(
        interval: const Duration(milliseconds: 5),
        invoke: (method, [args]) async => method == 'getInputGate'
            ? {
                'levelDb': -50.0,
                'voice': false,
                'strongNoiseSuppression': true,
              }
            : null,
        supported: true,
      ),
    );
  }

  final mic = _Mic();
  late final VoiceSession session;

  Future<void> join({bool micOn = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _wait(int ms) => Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  test('a frozen capture counter restarts the mic under active Strong',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.ticking = false;

    await _until(() => rig.mic.restarts == 1);
    await _wait(200);

    expect(rig.mic.restarts, 1);
    expect(rig.session.micStatus, MicStatus.ok);
  });

  test('a stale sender level does not excuse a frozen counter', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.ticking = false;
    rig.mic.healsOnRestart = false;

    await _until(() => rig.mic.restarts == 2);
    await _until(() => rig.session.micStatus == MicStatus.unavailable);

    expect(rig.session.micFailure, MicFailureReason.silent);
    expect(rig.mic.restarts, 2);
  });

  test('a counter that keeps moving restarts nothing', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();

    await _wait(300);

    expect(rig.mic.restarts, 0);
  });

  test('a counter that cannot be read is no verdict', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.readFails = true;

    await _wait(300);

    expect(rig.mic.restarts, 0);
  });

  test('a muted mic with a frozen counter restarts nothing', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join(micOn: false);
    rig.mic.ticking = false;

    await _wait(300);

    expect(rig.mic.restarts, 0);
  });
}
