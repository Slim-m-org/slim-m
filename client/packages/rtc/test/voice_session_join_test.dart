// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A join stamps its stages in order, and still publishes the microphone the
/// person chose.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _GatedRoom extends lk.Room {
  _GatedRoom(this.gate);

  final Completer<void> gate;

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) =>
      gate.future;
}

class _Mic implements MicPort {
  final published = <lk.AudioCaptureOptions?>[];
  bool hasTrackNow = false;

  @override
  bool get hasTrack => hasTrackNow;
  @override
  bool get open => hasTrackNow;
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled) published.add(options);
    hasTrackNow = enabled;
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
  Stream<void> get lost => const Stream.empty();
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async {}
}

class _Devices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [
        AudioDevice(id: 'mic-1', label: 'Headset'),
        AudioDevice(id: 'mic-2', label: 'Desk'),
      ];
  @override
  Future<List<AudioDevice>> outputs() async => const [];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Mic mic;
  late Completer<void> gate;
  late JoinTimings timings;
  late VoiceSession session;

  setUp(() async {
    mic = _Mic();
    gate = Completer<void>();
    timings = JoinTimings();
    session = VoiceSession(
      roomFactory: () => _GatedRoom(gate),
      micPort: mic,
      audioDevices: _Devices(),
      liveOutput: (room, device) async {},
      joinTimings: timings,
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.selectAudioInputDevice(
      const AudioDevice(id: 'mic-2', label: 'Desk'),
    );
  });

  Future<void> join({bool micOn = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );

  test('the chosen microphone is the one published', () async {
    final joined = join();
    gate.complete();
    await joined;

    expect(mic.published.single?.deviceId, 'mic-2');
  });

  test('a join with the microphone off publishes nothing', () async {
    final joined = join(micOn: false);
    gate.complete();
    await joined;

    expect(mic.published, isEmpty);
  });

  test('the stages are stamped in the order the join reaches them', () async {
    timings.begin();
    final joined = join();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    gate.complete();
    await joined;
    timings.finish();

    final millis = timings.last!.millis;
    final order = [
      JoinStage.click,
      JoinStage.connectStarted,
      JoinStage.connected,
      JoinStage.micPublished,
    ];
    expect(millis.keys.toSet(), order.toSet());
    final values = [for (final stage in order) millis[stage]!];
    expect([...values]..sort(), values);
  });
}
