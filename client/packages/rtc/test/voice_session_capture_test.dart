// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the session opens the microphone while Strong noise suppression is
/// chosen: libwebrtc's own suppression stays on, rnnoise is a native gate
/// flag, and libwebrtc's auto gain hands over to the chain's leveler, which
/// is the one reason a Strong switch reopens the capture. The real livekit
/// track behind [LiveKitMicPort] needs a native audio stack and stays
/// untested here.
library;

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
  final restartOptions = <lk.AudioCaptureOptions>[];
  final mutedReopens = <bool>[];

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
  Future<void> restart(lk.AudioCaptureOptions options) async {
    restarts.add(options.noiseSuppression);
    restartOptions.add(options);
  }

  @override
  Future<void> release() async {}

  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    mutedReopens.add(options.noiseSuppression);
    published = true;
    muted = true;
  }

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}

  @override
  Stream<void> get lost => const Stream.empty();

  @override
  void onRoomEvent(lk.RoomEvent event) {}

  @override
  Future<void> discard() async => published = false;
}

class _FakeGate {
  bool strongActive = true;
  final configured = <bool>[];
  final strongest = <bool>[];

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'setInputGate') {
      final map = args! as Map;
      configured.add(map['strongNoiseSuppression'] as bool);
      strongest.add(map['strongestNoiseSuppression'] as bool);
    }
    if (method == 'getInputGate') {
      return {
        'levelDb': -40.0,
        'voice': false,
        'strongNoiseSuppression': strongActive,
      };
    }
    return null;
  }
}

const _poll = Duration(milliseconds: 2);

class _Rig {
  _Rig({bool gateSupported = true}) {
    session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      inputGate: InputGateMonitor(
        interval: _poll,
        invoke: gate.invoke,
        supported: gateSupported,
      ),
    );
  }

  final mic = _FakeMic();
  final gate = _FakeGate();
  late final VoiceSession session;

  Future<void> join({bool mic = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: mic,
      );
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _quiet() =>
    Future<void>.delayed(const Duration(milliseconds: 120));

void main() {
  test('Strong active keeps libwebrtc suppression on in the capture options',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    await _until(() => rig.gate.configured.isNotEmpty);
    await _quiet();
    final (enabled, options) = rig.mic.enables.single;
    expect(enabled, isTrue);
    expect(options!.noiseSuppression, isTrue);
    expect(options.echoCancellation, isTrue);
    expect(options.autoGainControl, isFalse,
        reason: 'the chain levels after suppression instead of auto gain');
    expect(rig.gate.configured.last, isTrue, reason: 'rnnoise is on natively');
    expect(rig.mic.restarts, isEmpty, reason: 'chosen before the join');
  });

  test('Strongest asks the native gate for both rnnoise and DeepFilterNet',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true, strongest: true);
    await rig.join();
    await _until(() => rig.gate.configured.isNotEmpty);
    expect(rig.gate.configured.last, isTrue);
    expect(rig.gate.strongest.last, isTrue);
    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.gate.strongest.last == false);
    expect(rig.gate.configured.last, isTrue, reason: 'Strong stays on');
    expect(rig.mic.restarts, isEmpty);
  });

  test('hosts without the gate keep libwebrtc suppression and hold the device',
      () async {
    final ungated = _Rig(gateSupported: false);
    addTearDown(ungated.session.dispose);
    ungated.session.setStrongNoiseSuppression(true);
    await ungated.join();
    final options = ungated.mic.enables.single.$2!;
    expect(options.noiseSuppression, isTrue);
    expect(
      options.stopAudioCaptureOnMute,
      isFalse,
      reason: 'a mute holds the device for the grace period on every host',
    );
  });

  test(
      'switching Strong mid-call flips the gate flag and reopens the capture '
      'once, with auto gain handed to the chain', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.gate.configured.contains(true));
    await _until(() => rig.mic.restarts.isNotEmpty);
    expect(rig.mic.restartOptions.single.autoGainControl, isFalse);
    expect(rig.mic.restartOptions.single.noiseSuppression, isTrue,
        reason: "libwebrtc's own suppression stays on");
    await rig.session.setMicrophoneEnabled(false);
    rig.session.setStrongNoiseSuppression(false);
    await _until(() => rig.gate.configured.last == false);
    await rig.session.setMicrophoneEnabled(true);
    await _quiet();
    expect(rig.mic.restarts, hasLength(1),
        reason: 'a muted mic is not restarted');
    expect(rig.mic.mutedReopens, isEmpty);
    expect(rig.mic.enables.last.$2!.autoGainControl, isTrue,
        reason: 'Standard gives auto gain back');
    expect(
        rig.mic.enables.every((e) => e.$2?.noiseSuppression ?? true), isTrue);
  });

  test('inactive Strong leaves the capture and the choice alone', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    rig.gate.strongActive = false;
    await _quiet();
    expect(rig.mic.restarts, isEmpty);
    expect(rig.gate.configured.last, isTrue);
  });

  test('push to talk reopens the ready capture once for Strong, muted',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setInputGate(enabled: false, thresholdDb: -50);
    await rig.session.setKeepMicReady(true);
    await rig.join(mic: false);
    expect(rig.mic.mutedReopens, [true]);
    rig.session.setStrongNoiseSuppression(true);
    await _quiet();
    expect(rig.mic.mutedReopens, [true, true],
        reason: 'reopened muted so auto gain goes off before the key is held');
    await rig.session.setMicrophoneEnabled(true);
    expect(rig.mic.enables.last.$2!.noiseSuppression, isTrue);
    expect(rig.mic.enables.last.$2!.autoGainControl, isFalse);
    expect(rig.mic.restarts, isEmpty, reason: 'never restarted while muted');
  });
}
