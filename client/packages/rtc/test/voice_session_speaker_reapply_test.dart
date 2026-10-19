// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening the microphone makes the native plugin select the default speaker
/// again, so the chosen one has to be applied after every open.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _EmptyRoom extends lk.Room {
  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}
}

class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  int enables = 0;
  final _lost = StreamController<void>.broadcast();

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled) enables++;
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {}
  @override
  Future<void> release() async {}
  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {}
  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}
  @override
  Stream<void> get lost => _lost.stream;
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async => published = false;

  void end() {
    published = false;
    _lost.add(null);
  }
}

const _speaker = AudioDevice(id: 'spk-1', label: 'Speaker');

class _Devices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [];
  @override
  Future<List<AudioDevice>> outputs() async => const [_speaker];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  test('the chosen speaker is applied again after every microphone open',
      () async {
    final applied = <String>[];
    final mic = _Mic();
    final session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      micPort: mic,
      audioDevices: _Devices(),
      liveOutput: (room, device) async => applied.add(device.deviceId),
      micRecoveryTiming: const MicRecoveryTiming(
        retryBase: Duration(milliseconds: 10),
        maxRetryDelay: Duration(milliseconds: 20),
      ),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.selectAudioOutputDevice(_speaker);
    expect(applied, isEmpty);

    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: true,
    );
    await _until(() => applied.isNotEmpty);
    final afterJoin = applied.length;

    mic.end();
    await _until(() => mic.enables == 2);
    await _until(() => applied.length > afterJoin);

    expect(applied.toSet(), {'spk-1'});
  });
}
