// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Strong hands levelling to the native chain: libwebrtc's auto gain, which
/// runs before the suppressor, goes off at the capture and the chain's own
/// leveler goes on, and the capture reopens for it like any filter change.
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
  final restarts = <lk.AudioCaptureOptions>[];

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
  Future<void> release() async {}
  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async =>
      published = true;
  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<double?> capturedSeconds() async => null;
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

class _Gate {
  final configured = <Map<Object?, Object?>>[];

  Future<Object?> invoke(String method, [Object? args]) async {
    if (method == 'setInputGate') configured.add(args! as Map);
    return null;
  }
}

Future<(VoiceSession, _Mic, _Gate)> _joined({bool nativeGate = true}) async {
  final mic = _Mic();
  final gate = _Gate();
  final session = VoiceSession(
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    audioDevices: _NoDevices(),
    inputGate: InputGateMonitor(invoke: gate.invoke, supported: nativeGate),
    micReleaseGrace: const Duration(hours: 1),
  );
  await session.join(
      url: 'wss://a.invalid', token: 't', microphoneEnabled: true);
  return (session, mic, gate);
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('Strong turns auto gain off at the capture and the leveler on',
      () async {
    final (session, mic, gate) = await _joined();

    session.setStrongNoiseSuppression(true);
    await _settle();

    expect(mic.restarts, hasLength(1));
    expect(mic.restarts.single.autoGainControl, isFalse);
    expect(mic.restarts.single.noiseSuppression, isTrue);
    expect(gate.configured.last['levelAfterSuppression'], isTrue);
    expect(gate.configured.last['strongNoiseSuppression'], isTrue);
  });

  test('Standard again brings auto gain back and the leveler off', () async {
    final (session, mic, gate) = await _joined();
    session.setStrongNoiseSuppression(true);
    await _settle();

    session.setStrongNoiseSuppression(false);
    await _settle();

    expect(mic.restarts, hasLength(2));
    expect(mic.restarts.last.autoGainControl, isTrue);
    expect(gate.configured.last['levelAfterSuppression'], isFalse);
  });

  test('a member who turned auto gain off already is not reopened for Strong',
      () async {
    final (session, mic, gate) = await _joined();
    await session.setVoiceProcessing(
      const VoiceProcessing(autoGainControl: false),
    );
    expect(mic.restarts, hasLength(1));

    session.setStrongNoiseSuppression(true);
    await _settle();

    expect(mic.restarts, hasLength(1));
    expect(gate.configured.last['levelAfterSuppression'], isTrue);
  });

  test('picking Strong twice reopens once', () async {
    final (session, mic, _) = await _joined();
    session.setStrongNoiseSuppression(true);
    await _settle();
    session.setStrongNoiseSuppression(true, strongest: false);
    await _settle();
    expect(mic.restarts, hasLength(1));
  });

  test('Strongest levels natively like Strong', () async {
    final (session, mic, gate) = await _joined();
    session.setStrongNoiseSuppression(true, strongest: true);
    await _settle();
    expect(mic.restarts.single.autoGainControl, isFalse);
    expect(gate.configured.last['levelAfterSuppression'], isTrue);
  });

  test('without a native chain the capture keeps auto gain', () async {
    final (session, mic, _) = await _joined(nativeGate: false);
    session.setStrongNoiseSuppression(true);
    await _settle();
    expect(mic.restarts, isEmpty);
  });

  test('the capture options say when the chain levels instead of auto gain',
      () {
    final lines = <String>[];
    final switching = AudioDeviceSwitching(
      _NoDevices(),
      log: (line, {LogLevel level = LogLevel.info}) => lines.add(line),
    );
    expect(switching.captureOptions().autoGainControl, isTrue);

    switching.levelsNatively = () => true;
    final options = switching.captureOptions();

    expect(options.autoGainControl, isFalse);
    expect(options.noiseSuppression, isTrue);
    expect(lines.last, contains('agc off: the chain levels'));
  });
}
