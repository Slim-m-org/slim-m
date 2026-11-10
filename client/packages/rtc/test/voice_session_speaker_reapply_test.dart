// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opening the microphone makes the native plugin select the default speaker
/// again, so the chosen one has to be applied after every open.
library;

import 'dart:async';
import 'dart:io' show ProcessResult;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart' show pollUntil;

import 'support/session_fakes.dart';

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
  Future<double?> capturedSeconds() async => null;
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
const _serverSpeaker = AudioDevice(id: 'pulse:sink_b', label: 'B');

class _Devices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [];
  @override
  Future<List<AudioDevice>> outputs() async => const [_speaker, _serverSpeaker];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}

void main() {
  test('the chosen speaker is applied again after every microphone open',
      () async {
    final applied = <String>[];
    final mic = _Mic();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
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
    await pollUntil(() => applied.isNotEmpty);
    final afterJoin = applied.length;

    mic.end();
    await pollUntil(() => mic.enables == 2);
    await pollUntil(() => applied.length > afterJoin);

    expect(applied.toSet(), {'spk-1'});
  });

  test('a playback stream that starts mid-call lands on the chosen speaker',
      () async {
    final moves = <List<String>>[];
    final starts = StreamController<String>();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: _Mic(),
      audioDevices: _Devices(),
      pulse: PulseAudio(
        processId: 4242,
        run: (args) async {
          if (args.first.startsWith('move-')) moves.add(args);
          final listed = args.contains('sink-inputs')
              ? '[{"index":7,"properties":{"application.process.id":"4242"}}]'
              : '';
          return ProcessResult(0, 0, listed, '');
        },
        subscribe: () => starts.stream,
      ),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.selectAudioOutputDevice(_serverSpeaker);
    await session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: false,
    );
    moves.clear();

    starts.add("Event 'new' on sink-input #7");
    await pollUntil(() => moves.isNotEmpty);

    expect(moves.first, ['move-sink-input', '7', 'sink_b']);
  });
}
