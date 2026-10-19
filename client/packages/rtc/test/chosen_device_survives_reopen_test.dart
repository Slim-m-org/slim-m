// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone and speaker the person chose must be handed to the platform
/// on every way the capture opens again, not only the first: a reopen that
/// asks for no device lands on the system default and the pick looks lost.
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

/// Records the device every open, restart and held-muted reopen asked for.
class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  bool released = false;
  final opened = <String?>[];
  final _lost = StreamController<void>.broadcast();

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled) opened.add(options?.deviceId);
    published = true;
    muted = !enabled;
    if (enabled) released = false;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async =>
      opened.add(options.deviceId);
  @override
  Future<void> release() async => released = true;
  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    opened.add(options.deviceId);
    released = false;
  }

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

class _Devices implements AudioDevices {
  List<AudioDevice> mics = const [
    AudioDevice(id: 'mic-1', label: 'Headset'),
    AudioDevice(id: 'mic-2', label: 'Desk'),
  ];
  List<AudioDevice> speakers = const [AudioDevice(id: 'spk-1', label: 'Out')];
  final changes = StreamController<void>.broadcast();

  @override
  Future<List<AudioDevice>> inputs() async => mics;
  @override
  Future<List<AudioDevice>> outputs() async => speakers;
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => changes.stream;
}

const _timing = MicRecoveryTiming(
  retryBase: Duration(milliseconds: 10),
  maxRetryDelay: Duration(milliseconds: 20),
  silence: Duration(milliseconds: 60),
  silentCooldown: Duration(milliseconds: 30),
  deviceDebounce: Duration(milliseconds: 20),
  senderPoll: Duration(milliseconds: 5),
);

const _chosen = AudioDevice(id: 'mic-1', label: 'Headset');

class _Rig {
  _Rig({double levelDb = -40.0}) {
    session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      micPort: mic,
      audioDevices: devices,
      liveOutput: (room, device) async => outputs.add(device.deviceId),
      micRecoveryTiming: _timing,
      micReleaseGrace: const Duration(milliseconds: 30),
      captureRestartDebounce: const Duration(milliseconds: 10),
      inputGate: InputGateMonitor(
        interval: const Duration(milliseconds: 5),
        invoke: (method, [args]) async => method == 'getInputGate'
            ? {'levelDb': levelDb, 'voice': false}
            : null,
        supported: true,
      ),
    );
  }

  final mic = _Mic();
  final devices = _Devices();
  final outputs = <String>[];
  late final VoiceSession session;

  Future<void> choose() async {
    await session.selectAudioInputDevice(_chosen);
    await session
        .selectAudioOutputDevice(const AudioDevice(id: 'spk-1', label: 'Out'));
  }

  Future<void> join({bool micOn = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );

  /// Every capture open so far asked for the chosen microphone.
  void expectAllChosen() {
    expect(mic.opened, isNotEmpty);
    expect(mic.opened.toSet(), {'mic-1'});
  }
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle([int ms = 120]) =>
    Future<void>.delayed(Duration(milliseconds: ms));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Rig rig;

  Future<_Rig> start({bool micOn = true, double levelDb = -40.0}) async {
    rig = _Rig(levelDb: levelDb);
    addTearDown(rig.session.dispose);
    await rig.choose();
    await rig.join(micOn: micOn);
    return rig;
  }

  test('the first open of a call uses the chosen microphone', () async {
    await start();
    rig.expectAllChosen();
  });

  test('a lost track that recovery reopens uses the chosen microphone',
      () async {
    await start();
    rig.mic.end();
    await _until(() => rig.mic.opened.length >= 2);
    rig.expectAllChosen();
  });

  test('the silent-capture restart uses the chosen microphone', () async {
    await start(levelDb: kInputFloorDb);
    await _until(() => rig.mic.opened.length >= 2);
    rig.expectAllChosen();
  });

  test('turning Strong on or off reopens the chosen microphone', () async {
    await start();
    final before = rig.mic.opened.length;
    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.mic.opened.length > before);
    rig.session.setStrongNoiseSuppression(false);
    await _until(() => rig.mic.opened.length > before + 1);
    rig.expectAllChosen();
  });

  test('unmuting after the released-mute grace reopens the chosen microphone',
      () async {
    await start();
    await rig.session.setMicrophoneEnabled(false);
    await _until(() => rig.mic.released);
    await rig.session.setMicrophoneEnabled(true);
    rig.expectAllChosen();
    expect(rig.mic.opened.length, 2);
  });

  test('push to talk keeping the mic ready reopens the chosen microphone',
      () async {
    await start();
    await rig.session.setMicrophoneEnabled(false);
    await _until(() => rig.mic.released);
    await _settle(20);
    await rig.session.setKeepMicReady(true);
    rig.expectAllChosen();
    expect(rig.mic.opened.length, 2);
  });

  test('a repeated mute and unmute over a long call never drifts', () async {
    await start();
    for (var i = 0; i < 6; i++) {
      await rig.session.setMicrophoneEnabled(false);
      await _settle(50);
      await rig.session.setMicrophoneEnabled(true);
    }
    rig.expectAllChosen();
  });

  test('leaving and joining again uses the chosen microphone', () async {
    await start();
    await rig.session.leave();
    await rig.join();
    rig.expectAllChosen();
    expect(rig.mic.opened.length, 2);
  });

  test('a headset that blinks away and returns is used again', () async {
    await start();
    rig.devices.mics = const [AudioDevice(id: 'mic-2', label: 'Desk')];
    rig.devices.changes.add(null);
    await _settle();
    rig.devices.mics = const [
      AudioDevice(id: 'mic-1', label: 'Headset'),
      AudioDevice(id: 'mic-2', label: 'Desk'),
    ];
    rig.devices.changes.add(null);
    await _until(() => rig.mic.opened.length >= 3);
    expect(rig.mic.opened.last, 'mic-1');
  });

  test('a list that misses the headset for one read does not move the capture',
      () async {
    await start();
    final before = rig.mic.opened.length;
    rig.devices.mics = const [AudioDevice(id: 'mic-2', label: 'Desk')];
    rig.devices.changes.add(null);
    unawaited(Future<void>.delayed(const Duration(milliseconds: 30), () {
      rig.devices.mics = const [
        AudioDevice(id: 'mic-1', label: 'Headset'),
        AudioDevice(id: 'mic-2', label: 'Desk'),
      ];
    }));
    await _settle(300);
    expect(rig.mic.opened.length, before);
    expect(rig.session.audioInputInUse, 'mic-1');
  });

  test('a headset missing at unmute time is picked up when it is back',
      () async {
    await start();
    await rig.session.setMicrophoneEnabled(false);
    rig.devices.mics = const [AudioDevice(id: 'mic-2', label: 'Desk')];
    await rig.session.setMicrophoneEnabled(true);
    expect(rig.mic.opened.last, isNull, reason: 'unplugged: system default');

    await rig.session.setMicrophoneEnabled(false);
    rig.devices.mics = const [AudioDevice(id: 'mic-1', label: 'Headset')];
    await rig.session.setMicrophoneEnabled(true);
    expect(rig.mic.opened.last, 'mic-1');
  });

  test('an empty device list does not forget the choice', () async {
    await start();
    await rig.session.leave();
    rig.devices.mics = const [];
    rig.devices.speakers = const [];
    await rig.join();
    rig.expectAllChosen();
  });

  test('the chosen speaker is applied after every capture reopen', () async {
    await start();
    rig.mic.end();
    await _until(() => rig.mic.opened.length >= 2);
    await _until(() => rig.outputs.length >= 2);
    expect(rig.outputs.toSet(), {'spk-1'});
  });
}
