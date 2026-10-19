// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone opens while the connect is still in flight, and it is still
/// the one the person chose that gets published.
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

class _Mic implements MicPort, MicPreopen {
  final preopened = <lk.AudioCaptureOptions>[];
  final published = <lk.AudioCaptureOptions?>[];
  int discards = 0;
  bool hasTrackNow = false;

  @override
  Future<bool> preopen(lk.AudioCaptureOptions options) async {
    preopened.add(options);
    return true;
  }

  @override
  Future<void> discardPreopened() async => discards++;
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

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
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

  test('the chosen microphone opens before the connect returns', () async {
    timings.begin();
    final joined = join();
    await _until(() => mic.preopened.isNotEmpty);

    expect(gate.isCompleted, isFalse);
    expect(mic.preopened.single.deviceId, 'mic-2');
    expect(mic.published, isEmpty);

    gate.complete();
    await joined;

    expect(mic.published.single?.deviceId, 'mic-2');
    expect(sameMicCapture(mic.preopened.single, mic.published.single!), isTrue);
  });

  test('a join with the microphone off opens no capture', () async {
    final joined = join(micOn: false);
    gate.complete();
    await joined;

    expect(mic.preopened, isEmpty);
    expect(mic.published, isEmpty);
  });

  test('leaving while the connect is pending closes the capture', () async {
    final joined = join();
    await _until(() => mic.preopened.isNotEmpty);

    final left = session.leave();
    gate.complete();
    await Future.wait([joined, left]);

    expect(mic.discards, greaterThan(0));
  });

  test('the stages are stamped in the order the join reaches them', () async {
    timings.begin();
    final joined = join();
    await _until(() => mic.preopened.isNotEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    gate.complete();
    await joined;
    timings.finish();

    final millis = timings.last!.millis;
    final order = [
      JoinStage.click,
      JoinStage.connectStarted,
      JoinStage.micOpened,
      JoinStage.connected,
      JoinStage.micPublished,
    ];
    expect(millis.keys.toSet(), order.toSet());
    final values = [for (final stage in order) millis[stage]!];
    expect([...values]..sort(), values);
  });

  test('captures differ when the device or the processing differs', () {
    const base = lk.AudioCaptureOptions(deviceId: 'mic-1');

    expect(sameMicCapture(base, base.copyWith()), isTrue);
    expect(sameMicCapture(base, base.copyWith(deviceId: 'mic-2')), isFalse);
    expect(
        sameMicCapture(base, base.copyWith(noiseSuppression: false)), isFalse);
    expect(
      sameMicCapture(base, base.copyWith(stopAudioCaptureOnMute: false)),
      isFalse,
    );
  });
  micPortScopeTests();
}

void micPortScopeTests() {
  test('a phone never opens the capture ahead of the connect', () async {
    final port = LiveKitMicPort(() => null, mobile: true);

    expect(port.preopens, isFalse);
    expect(await port.preopen(const lk.AudioCaptureOptions()), isFalse);
  });

  test('a desktop or web client does', () {
    expect(LiveKitMicPort(() => null, mobile: false).preopens, isTrue);
  });
}
