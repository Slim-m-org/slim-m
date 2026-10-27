// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The input gate is read only as fast as its consumers need: not at all with
/// the microphone closed, at the watchdog's pace in a plain call, faster for
/// Strong or automatic sensitivity, and at the display rate only for a meter.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'support/no_audio_devices.dart';

import 'support/session_fakes.dart';

class _FakeMic implements MicPort {
  bool published = false;
  bool muted = true;
  final restarts = <bool>[];

  @override
  bool get hasTrack => published;

  @override
  Future<double?> senderLevelDb() async => null;

  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
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

const _tick = Duration(milliseconds: 2);

class _Rig {
  _Rig({this.levelDb = -40.0}) {
    gate = InputGateMonitor(
      interval: _tick,
      invoke: (method, [args]) async {
        if (method != 'getInputGate') return null;
        polls++;
        return {'levelDb': levelDb, 'voice': false};
      },
      supported: true,
    );
    session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      micRecoveryTiming: const MicRecoveryTiming(
        silence: Duration(milliseconds: 150),
        silentCooldown: Duration(milliseconds: 30),
      ),
      inputGate: gate,
    );
  }

  final double levelDb;
  final mic = _FakeMic();
  late final InputGateMonitor gate;
  late final VoiceSession session;
  int polls = 0;

  Future<void> join({required bool micOn}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );

  Future<int> pollsIn(Duration window) async {
    final before = polls;
    await Future<void>.delayed(window);
    return polls - before;
  }
}

void main() {
  late _Rig rig;

  Future<_Rig> start({required bool micOn, double levelDb = -40.0}) async {
    rig = _Rig(levelDb: levelDb);
    addTearDown(rig.session.dispose);
    await rig.join(micOn: micOn);
    return rig;
  }

  test('a muted call with nothing displayed does not poll at all', () async {
    await start(micOn: false);
    expect(rig.gate.rate, InputGateRate.off);
    expect(await rig.pollsIn(const Duration(milliseconds: 300)), 0);
  });

  test('an open mic with nothing displayed reads at the watchdog pace',
      () async {
    await start(micOn: true);
    expect(rig.gate.rate, InputGateRate.slow);
    final slow = await rig.pollsIn(const Duration(milliseconds: 400));
    rig.session.setLevelDisplayed(true);
    final shown = await rig.pollsIn(const Duration(milliseconds: 400));
    expect(slow, greaterThan(0));
    expect(slow, lessThan(shown ~/ 10));
  });

  test('Strong reads faster than the watchdog needs, and relaxes when off',
      () async {
    await start(micOn: true);
    rig.session.setStrongNoiseSuppression(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.gate.rate, InputGateRate.watch);
    rig.session.setStrongNoiseSuppression(false);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.gate.rate, InputGateRate.slow);
  });

  test('automatic sensitivity adapts faster than the watchdog', () async {
    await start(micOn: true);
    rig.session.setAutoInputThreshold(true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(rig.gate.rate, InputGateRate.adapt);
  });

  test('muting stops the polling and unmuting resumes it', () async {
    await start(micOn: true);
    expect(rig.gate.rate, InputGateRate.slow);
    await rig.session.setMicrophoneEnabled(false);
    expect(rig.gate.rate, InputGateRate.off);
    expect(await rig.pollsIn(const Duration(milliseconds: 300)), 0);
    await rig.session.setMicrophoneEnabled(true);
    expect(rig.gate.rate, InputGateRate.slow);
    expect(
        await rig.pollsIn(const Duration(milliseconds: 300)), greaterThan(0));
  });

  test('a displayed meter reads even while muted, then stops with it',
      () async {
    await start(micOn: false);
    rig.session.setLevelDisplayed(true);
    expect(rig.gate.rate, InputGateRate.display);
    rig.session.setLevelDisplayed(false);
    expect(rig.gate.rate, InputGateRate.off);
  });

  test('the dead-mic watchdog still restarts a capture reading silence',
      () async {
    await start(micOn: true, levelDb: kInputFloorDb);
    expect(rig.gate.rate, InputGateRate.slow);
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (rig.mic.restarts.isEmpty) {
      if (DateTime.now().isAfter(deadline)) fail('watchdog never fired');
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });

  test('a muted silent mic is not mistaken for a dead one', () async {
    await start(micOn: false, levelDb: kInputFloorDb);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(rig.mic.restarts, isEmpty);
  });
}
