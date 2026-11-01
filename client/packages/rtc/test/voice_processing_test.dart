// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Echo, gain and suppression are fixed when the capture opens, so a change
/// reopens an open one and leaves a muted one to open with the new filters.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  int releases = 0;
  int reopens = 0;
  final restarts = <lk.AudioCaptureOptions>[];
  final adopted = <lk.AudioCaptureOptions>[];

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async =>
      restarts.add(options);
  @override
  Future<void> release() async => releases++;
  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    reopens++;
    published = true;
  }

  @override
  void adoptOptions(lk.AudioCaptureOptions options) => adopted.add(options);
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Stream<void> get lost => const Stream.empty();
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async => published = false;
}

class _NoDevices implements AudioDevices {
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

const _noEcho = VoiceProcessing(echoCancellation: false);

Future<(VoiceSession, _Mic)> _joined({required bool microphoneEnabled}) async {
  final mic = _Mic();
  final session = VoiceSession(
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    audioDevices: _NoDevices(),
    micReleaseGrace: const Duration(hours: 1),
  );
  await session.join(
    url: 'wss://a.invalid',
    token: 't',
    microphoneEnabled: microphoneEnabled,
  );
  return (session, mic);
}

void main() {
  test('an open microphone restarts with the new filters', () async {
    final (session, mic) = await _joined(microphoneEnabled: true);

    await session.setVoiceProcessing(_noEcho);

    expect(mic.restarts, hasLength(1));
    expect(mic.restarts.single.echoCancellation, isFalse);
    expect(mic.restarts.single.autoGainControl, isTrue);
    expect(mic.restarts.single.noiseSuppression, isTrue);
  });

  test('setting what is already set restarts nothing', () async {
    final (session, mic) = await _joined(microphoneEnabled: true);

    await session.setVoiceProcessing(const VoiceProcessing());

    expect(mic.restarts, isEmpty);
  });

  test('a muted microphone gives the capture back to open fresh', () async {
    final (session, mic) = await _joined(microphoneEnabled: true);
    await session.setMicrophoneEnabled(false);

    await session.setVoiceProcessing(
      const VoiceProcessing(autoGainControl: false),
    );

    expect(mic.restarts, isEmpty);
    expect(mic.releases, 1);
    expect(mic.adopted.last.autoGainControl, isFalse);
  });

  test('a push-to-talk microphone is reopened muted, not released', () async {
    final (session, mic) = await _joined(microphoneEnabled: true);
    await session.setKeepMicReady(true);
    await session.setMicrophoneEnabled(false);
    final before = mic.reopens;

    await session.setVoiceProcessing(
      const VoiceProcessing(noiseSuppression: false),
    );

    expect(mic.releases, 0);
    expect(mic.reopens, before + 1);
  });

  test('before a call the filters only ride on the next capture', () async {
    final mic = _Mic();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      audioDevices: _NoDevices(),
    );

    await session.setVoiceProcessing(_noEcho);

    expect(mic.restarts, isEmpty);
    expect(mic.releases, 0);
  });

  test('the capture options carry the filters and the log names them', () {
    final lines = <String>[];
    final switching = AudioDeviceSwitching(
      _NoDevices(),
      log: (m, {level = LogLevel.info}) => lines.add(m),
    )..processing = const VoiceProcessing(
        echoCancellation: false,
        autoGainControl: false,
        noiseSuppression: false,
      );

    final options = switching.captureOptions();

    expect(options.echoCancellation, isFalse);
    expect(options.autoGainControl, isFalse);
    expect(options.noiseSuppression, isFalse);
    expect(lines.single, endsWith('webrtc_ns=off aec=off agc=off'));
  });
}
