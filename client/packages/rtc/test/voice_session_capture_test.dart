// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the session opens and reopens the microphone for Strong noise
/// suppression, driven through the mic and gate seams. The real livekit track
/// behind [LiveKitMicPort] needs a native audio stack and stays untested here.
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
  final mutedReopens = <bool>[];

  @override
  bool get hasTrack => published;

  double? senderLevel;

  @override
  Future<double?> senderLevelDb() async => senderLevel;

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

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'setInputGate') {
      configured.add((args! as Map)['strongNoiseSuppression'] as bool);
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

const _debounce = Duration(milliseconds: 20);
const _poll = Duration(milliseconds: 2);

class _Rig {
  _Rig({bool gateSupported = true}) {
    session = VoiceSession(
      audioDevices: const NoAudioDevices(),
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      captureRestartDebounce: _debounce,
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

Future<void> _quiet() => Future<void>.delayed(_debounce * 6);

void main() {
  test('enabling the mic under Strong opens it without libwebrtc suppression',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    final (enabled, options) = rig.mic.enables.single;
    expect(enabled, isTrue);
    expect(options!.noiseSuppression, isFalse);
    expect(options.echoCancellation, isTrue);
    expect(options.autoGainControl, isTrue);
  });

  test('Standard and hosts without the gate keep libwebrtc suppression',
      () async {
    final standard = _Rig();
    addTearDown(standard.session.dispose);
    await standard.join();
    expect(standard.mic.enables.single.$2!.noiseSuppression, isTrue);

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

  test('a mid-call switch to Strong reopens the mic once, not while muted',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.mic.restarts.isNotEmpty);
    await _quiet();
    expect(rig.mic.restarts, [false]);

    await rig.session.setMicrophoneEnabled(false);
    rig.session.setStrongNoiseSuppression(false);
    await _quiet();
    expect(rig.mic.restarts, [false], reason: 'muted: deferred');

    await rig.session.setMicrophoneEnabled(true);
    await _until(() => rig.mic.restarts.length == 2);
    expect(rig.mic.restarts, [false, true]);
  });

  test('inactive Strong puts libwebrtc back, and the gate flag follows',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    rig.gate.strongActive = false;
    await _until(() => rig.mic.restarts.isNotEmpty);
    expect(rig.mic.restarts, [true]);

    rig.gate.strongActive = true;
    rig.session.setStrongNoiseSuppression(false);
    await _quiet();
    expect(rig.gate.configured.last, isFalse);
  });

  test('Standard keeps rnnoise running until libwebrtc is back on', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    rig.session.setStrongNoiseSuppression(false);
    expect(rig.gate.configured.last, isTrue, reason: 'not off yet');
    await _until(() => rig.mic.restarts.isNotEmpty);
    await _until(() => rig.gate.configured.last == false);
  });

  test('a fallback does not carry into the next call', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.session.setStrongNoiseSuppression(true);
    await rig.join();
    rig.gate.strongActive = false;
    await _until(() => rig.mic.restarts.isNotEmpty);

    rig.gate.strongActive = true;
    await rig.session.leave();
    await rig.join();
    expect(rig.mic.enables.last.$2!.noiseSuppression, isFalse);
  });

  group('push to talk', () {
    Future<_Rig> pttRig() async {
      final rig = _Rig();
      addTearDown(rig.session.dispose);
      rig.session.setInputGate(enabled: false, thresholdDb: -50);
      await rig.session.setKeepMicReady(true);
      await rig.join(mic: false);
      expect(rig.mic.mutedReopens, [true], reason: 'primed with Standard');
      return rig;
    }

    test('Strong chosen mid-call is running before the key goes down',
        () async {
      final rig = await pttRig();
      rig.session.setStrongNoiseSuppression(true);
      await _until(() => rig.mic.mutedReopens.length == 2);
      expect(rig.mic.mutedReopens, [true, false]);

      await rig.session.setMicrophoneEnabled(true);
      await _quiet();
      expect(rig.mic.restarts, isEmpty, reason: 'no reopen while talking');
      expect(rig.mic.enables.last.$2!.noiseSuppression, isFalse);
    });

    test('a key held through a Strong change reopens after the release',
        () async {
      final rig = await pttRig();
      await rig.session.setMicrophoneEnabled(true);
      rig.session.setStrongNoiseSuppression(true);
      await _quiet();
      expect(rig.mic.restarts, isEmpty);
      expect(rig.mic.mutedReopens, [true]);

      await rig.session.setMicrophoneEnabled(false);
      await _until(() => rig.mic.mutedReopens.length == 2);
      expect(rig.mic.mutedReopens, [true, false]);
    });
  });
}
