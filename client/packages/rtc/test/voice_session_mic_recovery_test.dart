// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A microphone that dies under a call comes back: ended tracks, device
/// changes, a silent capture and a failed Strong reopen, driven through the
/// mic, gate and device seams.
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

class _FakeMic implements MicPort {
  bool published = false;
  bool muted = true;
  int enables = 0;
  int discards = 0;
  int enableFailures = 0;
  bool Function(bool noiseSuppression) restartFails = (_) => false;
  final restarts = <bool>[];
  final restartDevices = <String?>[];
  final _lost = StreamController<void>.broadcast();

  @override
  bool get hasTrack => published;

  double? senderLevel;

  @override
  Future<double?> senderLevelDb() async => senderLevel;

  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled && enableFailures > 0) {
      enableFailures--;
      throw StateError('no capture device');
    }
    if (enabled) enables++;
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    restarts.add(options.noiseSuppression);
    restartDevices.add(options.deviceId);
    if (restartFails(options.noiseSuppression)) throw StateError('restart');
  }

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
  Future<void> discard() async {
    discards++;
    published = false;
  }

  /// What livekit does when the capture ends underneath the call.
  void end() {
    published = false;
    _lost.add(null);
  }
}

class _Devices implements AudioDevices {
  List<AudioDevice> mics = const [];
  AudioDevice? systemDefault;
  final changes = StreamController<void>.broadcast();

  @override
  Future<List<AudioDevice>> inputs() async => mics;

  @override
  Future<List<AudioDevice>> outputs() async => const [];

  @override
  Future<AudioDevice?> systemDefaultInput() async => systemDefault;

  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;

  @override
  Stream<void> get onChange => changes.stream;
}

const _timing = MicRecoveryTiming(
  retryBase: Duration(milliseconds: 10),
  maxRetryDelay: Duration(milliseconds: 20),
  maxRetries: 3,
  silence: Duration(milliseconds: 60),
  silentCooldown: Duration(milliseconds: 30),
  maxSilentRestarts: 2,
  deviceDebounce: Duration(milliseconds: 20),
  senderPoll: Duration(milliseconds: 5),
);

class _Rig {
  _Rig({
    this.levelDb = -40.0,
    bool strong = false,
    bool gate = true,
    this.strongActive = false,
  }) {
    session = VoiceSession(
      roomFactory: _EmptyRoom.new,
      micPort: mic,
      audioDevices: devices,
      micRecoveryTiming: _timing,
      captureRestartDebounce: const Duration(milliseconds: 10),
      inputGate: InputGateMonitor(
        interval: const Duration(milliseconds: 5),
        invoke: (method, [args]) async => method == 'getInputGate'
            ? {
                'levelDb': levelDb,
                'voice': false,
                'strongNoiseSuppression': strongActive,
              }
            : null,
        supported: gate,
      ),
    );
    if (strong) session.setStrongNoiseSuppression(true);
    session.micStatuses.listen(statuses.add);
  }

  final mic = _FakeMic();
  final devices = _Devices();
  final double levelDb;
  final bool strongActive;
  final statuses = <MicStatus>[];
  late final VoiceSession session;

  Future<void> join({bool micOn = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );
}

Future<void> _until(bool Function() done) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!done()) {
    if (DateTime.now().isAfter(deadline)) fail('timed out waiting');
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 250));

void main() {
  test('an ended track is re-enabled while the user wants the mic open',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    expect(rig.mic.enables, 1);

    rig.mic.end();
    await _until(() => rig.mic.enables == 2);
    await _until(() => rig.session.micStatus == MicStatus.ok);

    expect(rig.mic.open, isTrue);
    expect(rig.statuses, [MicStatus.reconnecting, MicStatus.ok]);
  });

  test('a lost track stays gone when the user muted or joined muted', () async {
    final muted = _Rig();
    addTearDown(muted.session.dispose);
    await muted.join(micOn: false);
    muted.mic.end();
    await _settle();
    expect(muted.mic.enables, 0);
    expect(muted.session.micStatus, MicStatus.ok);

    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    await rig.session.setMicrophoneEnabled(false);
    rig.mic.end();
    await _settle();
    expect(rig.mic.enables, 1);
  });

  test('retries back off, give up as unavailable and a reset recovers',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.enableFailures = 100;

    rig.mic.end();
    await _until(() => rig.session.micStatus == MicStatus.unavailable);
    expect(rig.mic.enables, 1);

    rig.mic.enableFailures = 0;
    expect(await rig.session.resetMicrophone(), isTrue);
    expect(rig.mic.open, isTrue);
    expect(rig.session.micStatus, MicStatus.ok);
  });

  test('an unplugged chosen mic reopens the capture on the default', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    const headset = AudioDevice(id: 'usb', label: 'USB headset');
    rig.devices.mics = const [headset];
    await rig.session.selectAudioInputDevice(headset);
    await rig.join();
    expect(rig.mic.restarts, isEmpty);

    rig.devices.mics = const [];
    rig.devices.changes
      ..add(null)
      ..add(null);
    await _until(() => rig.mic.restarts.isNotEmpty);
    await _settle();

    expect(rig.mic.restarts, hasLength(1));
  });

  test('a mic that will not open at join is retried and reported', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.mic.enableFailures = 1;
    await rig.join();
    expect(rig.mic.open, isFalse);

    await _until(() => rig.mic.open);
    await _until(() => rig.session.micStatus == MicStatus.ok);
    expect(rig.statuses, [MicStatus.reconnecting, MicStatus.ok]);
  });

  test('a mic that never opens at join ends as unavailable, not silent',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.mic.enableFailures = 100;
    await rig.join();

    await _until(() => rig.session.micStatus == MicStatus.unavailable);
  });

  test('a muted join does not try to open the mic', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    rig.mic.enableFailures = 100;
    await rig.join(micOn: false);
    await _settle();

    expect(rig.session.micStatus, MicStatus.ok);
    expect(rig.mic.enableFailures, 100);
  });

  test('a chosen mic that comes back is used again, not left on the default',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    const headset = AudioDevice(id: 'bt', label: 'Headset');
    rig.devices.mics = const [headset];
    await rig.session.selectAudioInputDevice(headset);
    await rig.join();

    rig.devices.mics = const [];
    rig.devices.changes.add(null);
    await _until(() => rig.mic.restartDevices.isNotEmpty);
    expect(rig.mic.restartDevices.last, isNull);

    rig.devices.mics = const [headset];
    rig.devices.changes.add(null);
    await _until(() => rig.mic.restartDevices.length == 2);
    expect(rig.mic.restartDevices.last, 'bt');
  });

  test('a device change with a healthy capture restarts nothing', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();

    rig.devices.changes.add(null);
    await _settle();

    expect(rig.mic.restarts, isEmpty);
  });

  test('a device change after the track vanished republishes it', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.published = false;

    rig.devices.changes.add(null);
    await _until(() => rig.mic.enables == 2);
  });

  test('a mic reading digital silence is restarted, up to the cap', () async {
    final rig = _Rig(levelDb: kInputFloorDb);
    addTearDown(rig.session.dispose);
    await rig.join();

    await _until(() => rig.mic.restarts.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.mic.restarts, hasLength(2));
  });

  test('a quiet room under active Strong suppression is not restarted',
      () async {
    final rig = _Rig(levelDb: kInputFloorDb, strongActive: true);
    addTearDown(rig.session.dispose);
    await rig.join();

    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.mic.restarts, isEmpty);
  });

  test('a live level or a muted mic never trips the watchdog', () async {
    final live = _Rig();
    addTearDown(live.session.dispose);
    await live.join();
    final muted = _Rig(levelDb: kInputFloorDb);
    addTearDown(muted.session.dispose);
    await muted.join(micOn: false);

    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(live.mic.restarts, isEmpty);
    expect(muted.mic.restarts, isEmpty);
  });

  test('a Strong reopen that fails leaves the mic open on libwebrtc', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.restartFails = (ns) => !ns;

    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.mic.restarts.length >= 2);
    await _settle();

    expect(rig.mic.restarts, [false, true]);
    expect(rig.mic.open, isTrue);
    expect(rig.mic.discards, 0);
  });

  test('a Strong reopen that fails every way republishes the track', () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.restartFails = (_) => true;

    rig.session.setStrongNoiseSuppression(true);
    await _until(() => rig.mic.discards == 1);
    await _until(() => rig.mic.enables == 2);
    await _settle();

    expect(rig.mic.open, isTrue);
    expect(rig.session.micStatus, MicStatus.ok);
  });

  test('Reset microphone restarts an open capture with the current options',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();

    expect(await rig.session.resetMicrophone(), isTrue);

    expect(rig.mic.restarts, [true]);
    expect(rig.mic.open, isTrue);
  });

  test('Reset microphone while muted drops the track for a fresh unmute',
      () async {
    final rig = _Rig();
    addTearDown(rig.session.dispose);
    await rig.join();
    await rig.session.setMicrophoneEnabled(false);

    expect(await rig.session.resetMicrophone(), isTrue);
    expect(rig.mic.hasTrack, isFalse);
    expect(rig.mic.restarts, isEmpty);

    await rig.session.setMicrophoneEnabled(true);
    expect(rig.mic.open, isTrue);
  });

  test('a host without the gate restarts a capture the sender reports silent',
      () async {
    final rig = _Rig(gate: false);
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.senderLevel = kInputFloorDb;

    await _until(() => rig.mic.restarts.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.mic.restarts, hasLength(2));
  });

  test('a host without the gate leaves a live or quiet capture alone',
      () async {
    final rig = _Rig(gate: false);
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.senderLevel = senderLevelToDb(0.0001);

    await Future<void>.delayed(const Duration(milliseconds: 400));

    expect(rig.mic.restarts, isEmpty);
  });

  test('silence that outlasts every restart is reported, then clears',
      () async {
    final rig = _Rig(gate: false);
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.senderLevel = kInputFloorDb;

    await _until(() => rig.session.micStatus == MicStatus.unavailable);
    expect(rig.mic.restarts, hasLength(2));

    rig.mic.senderLevel = -30;
    await _until(() => rig.session.micStatus == MicStatus.ok);
  });

  test('retrying after giving up restores the status and the budget', () async {
    final rig = _Rig(gate: false);
    addTearDown(rig.session.dispose);
    await rig.join();
    rig.mic.senderLevel = kInputFloorDb;
    await _until(() => rig.session.micStatus == MicStatus.unavailable);

    expect(await rig.session.resetMicrophone(), isTrue);

    expect(rig.session.micStatus, MicStatus.ok);
  });

  test('a new system default microphone moves a capture that follows it',
      () async {
    final rig = _Rig();
    rig.devices.systemDefault = const AudioDevice(id: 'a', label: 'a');
    addTearDown(rig.session.dispose);
    await rig.join();
    await Future<void>.delayed(const Duration(milliseconds: 20));

    rig.devices.systemDefault = const AudioDevice(id: 'b', label: 'b');
    rig.devices.changes.add(null);

    await _until(() => rig.mic.restarts.length == 1);
  });

  test('a speaker change does not reopen a capture on the same default',
      () async {
    final rig = _Rig();
    rig.devices.systemDefault = const AudioDevice(id: 'a', label: 'a');
    addTearDown(rig.session.dispose);
    await rig.join();

    rig.devices.changes.add(null);
    await _settle();

    expect(rig.mic.restarts, isEmpty);
  });
}
