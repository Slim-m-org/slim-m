// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A microphone the watchdog gave up on is swapped for another one for this
/// call only, each candidate once, and the device lines reach the log.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

const _sys = AudioDevice(id: 'sys', label: 'System mic');
const _usb = AudioDevice(id: 'usb', label: 'USB headset');
const _sonar = AudioDevice(id: 'son', label: 'SteelSeries Sonar - Microphone');
const _desk = AudioDevice(id: 'desk', label: 'Desk mic');

class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  final restartDevices = <String?>[];
  String? current;

  /// Device id ('' for the system default) to the level it sends.
  final levels = <String, double>{};

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<double?> senderLevelDb() async => levels[current ?? ''] ?? -30;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    published = true;
    muted = !enabled;
    current = options?.deviceId;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    current = options.deviceId;
    restartDevices.add(options.deviceId);
  }

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
  Future<void> discard() async => published = false;
}

class _Devices implements AudioDevices {
  List<AudioDevice> mics = const [_usb, _sonar, _desk];
  List<AudioDevice> speakers = const [
    AudioDevice(id: 'spk', label: 'Speakers'),
  ];

  @override
  Future<List<AudioDevice>> inputs() async => mics;
  @override
  Future<List<AudioDevice>> outputs() async => speakers;
  @override
  Future<AudioDevice?> systemDefaultInput() async => _sys;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => speakers.first;
  final changes = StreamController<void>.broadcast();
  @override
  Stream<void> get onChange => changes.stream;
}

const _timing = MicRecoveryTiming(
  silence: Duration.zero,
  silentCooldown: Duration.zero,
  maxSilentRestarts: 1,
  senderPoll: Duration(seconds: 1),
  fallbackSettle: Duration(seconds: 1),
);

class _Rig {
  final mic = _Mic();
  final devices = _Devices();
  final logs = <String>[];
  final outputs = <String>[];
  final statuses = <MicStatus>[];
  late final VoiceSession session = VoiceSession(
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    audioDevices: devices,
    micRecoveryTiming: _timing,
    inputGate: InputGateMonitor.disabled(),
    audioLog: (m, {level = LogLevel.info}) => logs.add(m),
    liveInput: (room, device) async {},
    liveOutput: (room, device) async => outputs.add(device.deviceId),
  );
}

/// Joins with the chosen mic [chosen] (null: the system default) and runs until the fallback settles.
_Rig _run(
  FakeAsync clock, {
  AudioDevice? chosen,
  Set<String> dead = const {''},
  bool enabled = true,
  AudioDevice? output,
}) {
  final rig = _Rig();
  rig.session.micStatuses.listen(rig.statuses.add);
  rig.session.setMicFallbackEnabled(enabled);
  for (final id in dead) {
    rig.mic.levels[id] = kInputFloorDb;
  }
  unawaited(() async {
    await rig.session.selectAudioInputDevice(chosen);
    await rig.session.selectAudioOutputDevice(output);
    await rig.session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: true,
    );
  }());
  clock.flushMicrotasks();
  clock.elapse(const Duration(seconds: 60));
  return rig;
}

void main() {
  test('a dead chosen mic falls back to the system default first', () {
    fakeAsync((clock) {
      final rig = _run(clock, chosen: _usb, dead: {'usb'});

      expect(rig.mic.restartDevices.last, isNull);
      expect(rig.session.audioInputInUse, isNull);
      expect(rig.session.micStatus, MicStatus.ok);
      expect(rig.session.micFallbackNotice, 'System mic');
      expect(
        rig.logs,
        contains(
            'Switching microphone to the system default for this call only'),
      );
    });
  });

  test('a dead default falls to the next real mic, not the virtual one', () {
    fakeAsync((clock) {
      final rig = _run(clock, dead: {''});

      expect(rig.mic.restartDevices.whereType<String>(), ['usb']);
      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.micFallbackNotice, 'USB headset');
      expect(rig.session.micStatus, MicStatus.ok);
    });
  });

  test('every candidate is tried once and then the mic stays unavailable', () {
    fakeAsync((clock) {
      final rig = _run(clock, dead: {'', 'usb', 'son', 'desk'});
      final tried = rig.mic.restartDevices.whereType<String>().toList();
      clock.elapse(const Duration(minutes: 10));

      expect(tried.toSet(), {'usb', 'desk', 'son'});
      expect(tried.where((id) => id == 'usb'), hasLength(1));
      expect(
        rig.mic.restartDevices.whereType<String>(),
        tried,
        reason: 'no further restarts once every candidate was tried',
      );
      expect(rig.session.micStatus, MicStatus.unavailable);
      expect(rig.session.micFailure, MicFailureReason.silent);
      expect(rig.session.micFallbackNotice, isNull);
    });
  });

  test('a second failure never goes back to a device already tried', () {
    fakeAsync((clock) {
      final rig = _run(clock, dead: {''});
      expect(rig.session.audioInputInUse, 'usb');

      rig.mic.levels['usb'] = kInputFloorDb;
      clock.elapse(const Duration(seconds: 60));

      final after = rig.mic.restartDevices.skipWhile((d) => d != 'usb');
      expect(after, isNot(contains(null)));
      expect(rig.session.audioInputInUse, 'desk');
      expect(rig.session.micStatus, MicStatus.ok);
    });
  });

  test('with the setting off nothing is switched', () {
    fakeAsync((clock) {
      final rig = _run(clock, enabled: false, dead: {''});

      expect(rig.mic.restartDevices.whereType<String>(), isEmpty);
      expect(rig.session.audioInputInUse, isNull);
      expect(rig.session.micStatus, MicStatus.unavailable);
      expect(rig.session.micFallbackNotice, isNull);
    });
  });

  test('a chosen speaker goes back to the system default', () {
    fakeAsync((clock) {
      const other = AudioDevice(id: 'hp', label: 'Headphones');
      final rig = _Rig()
        ..devices.speakers = const [
          AudioDevice(id: 'spk', label: 'Speakers'),
          other
        ];
      rig.mic.levels[''] = kInputFloorDb;
      unawaited(() async {
        await rig.session.selectAudioOutputDevice(other);
        await rig.session.join(
          url: 'wss://a.invalid',
          token: 't',
          microphoneEnabled: true,
        );
      }());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));

      expect(rig.session.audioOutputInUse, isNull);
      expect(rig.logs, contains('Speaker moved back to the system default'));
    });
  });

  test('the fallback leaves the chosen mic and speaker for the next call', () {
    fakeAsync((clock) {
      const other = AudioDevice(id: 'hp', label: 'Headphones');
      final rig = _Rig()
        ..devices.speakers = const [
          AudioDevice(id: 'spk', label: 'Speakers'),
          other
        ];
      rig.mic.levels['usb'] = kInputFloorDb;
      unawaited(() async {
        await rig.session.selectAudioInputDevice(_usb);
        await rig.session.selectAudioOutputDevice(other);
        await rig.session.join(
          url: 'wss://a.invalid',
          token: 't',
          microphoneEnabled: true,
        );
      }());
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 60));
      expect(rig.session.audioInputInUse, isNull);
      expect(rig.session.audioOutputInUse, isNull);

      unawaited(rig.session.leave());
      clock.flushMicrotasks();

      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.audioOutputInUse, 'hp');
    });
  });

  test('the fallback is kept through a device change while it is plugged in',
      () {
    fakeAsync((clock) {
      final rig = _run(clock, chosen: _usb, dead: {'usb'});
      expect(rig.session.audioInputInUse, isNull);

      rig.devices.changes.add(null);
      clock.elapse(const Duration(seconds: 5));

      expect(rig.session.audioInputInUse, isNull);
    });
  });

  test('the devices and the microphone list reach the log', () {
    fakeAsync((clock) {
      final rig = _run(clock, chosen: _usb, dead: {'usb'});

      expect(
        rig.logs,
        contains('Microphones: USB headset | '
            'SteelSeries Sonar - Microphone | Desk mic'),
      );
      expect(
        rig.logs.where(
            (l) => l.startsWith('Audio devices (join): mic "USB headset";')),
        isNotEmpty,
      );
      expect(
        rig.logs.where((l) => l.contains('(usb)') || l.contains('(sys)')),
        isEmpty,
        reason: 'labels are logged, raw device ids are not',
      );
      expect(
        rig.logs.where((l) => l.startsWith('Audio devices (restart: silent)')),
        isNotEmpty,
      );
      expect(
        rig.logs.where((l) => l.startsWith('Audio devices (gave up)')),
        isNotEmpty,
      );
      expect(
        rig.logs.where((l) => l.startsWith('Audio devices (fallback)')),
        isNotEmpty,
      );
    });
  });

  test('candidates put the default first, then hardware before virtual', () {
    final picked = fallbackCandidates(
      inputs: const [_sonar, _usb, _desk],
      inUseId: 'usb',
      tried: {'usb'},
    );
    expect(picked.map((d) => d?.id), [null, 'desk', 'son']);
    expect(
      fallbackCandidates(
        inputs: const [_sonar, _usb],
        inUseId: null,
        tried: {''},
      ).map((d) => d?.id),
      ['usb', 'son'],
    );
  });
}
