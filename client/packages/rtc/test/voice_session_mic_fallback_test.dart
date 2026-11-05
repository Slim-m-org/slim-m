// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A microphone that vanished from under the call is swapped for another one
/// for this call only, each candidate once, and the device lines reach the log.
/// Silence alone never switches anything.
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
  final _lost = StreamController<void>.broadcast();
  String? current;
  double _counter = 0;

  /// Device ids ('' for the system default) that cannot be opened.
  final closed = <String>{};

  /// Device ids whose capture opens but never moves.
  final stalled = <String>{};

  /// What every device sends, exact zeros included.
  double level = -30;

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<double?> senderLevelDb() async => level;

  @override
  Future<double?> capturedSeconds() async =>
      stalled.contains(current ?? '') ? _counter : _counter += 1;

  void _open(String? id) {
    if (closed.contains(id ?? '')) throw StateError('cannot open $id');
    current = id;
  }

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    if (enabled) _open(options?.deviceId);
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    _open(options.deviceId);
    restartDevices.add(options.deviceId);
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
  Future<void> discard() async => published = false;

  void end() {
    published = false;
    _lost.add(null);
  }
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
  retryBase: Duration(milliseconds: 10),
  maxRetryDelay: Duration(milliseconds: 20),
  maxRetries: 2,
  quietNote: Duration.zero,
  captureStall: Duration.zero,
  restartCooldown: Duration.zero,
  maxRestarts: 1,
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

  /// The device in use is unplugged: gone from the list, its track ended,
  /// and the ids in [alsoClosed] cannot be reopened either.
  void unplug(String id, {Set<String> alsoClosed = const {}}) {
    devices.mics = [
      for (final d in devices.mics)
        if (d.id != id) d,
    ];
    mic.closed
      ..add(id)
      ..addAll(alsoClosed);
    mic.end();
  }
}

/// Joins with the chosen mic [chosen] (null: the system default), then runs a minute.
_Rig _join(
  FakeAsync clock, {
  AudioDevice? chosen,
  bool enabled = true,
  AudioDevice? output,
  _Rig? rig,
}) {
  final joined = rig ?? _Rig();
  joined.session.micStatuses.listen(joined.statuses.add);
  joined.session.setMicFallbackEnabled(enabled);
  unawaited(() async {
    await joined.session.selectAudioInputDevice(chosen);
    await joined.session.selectAudioOutputDevice(output);
    await joined.session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: true,
    );
  }());
  clock.flushMicrotasks();
  clock.elapse(const Duration(seconds: 5));
  return joined;
}

void _minutes(FakeAsync clock, int minutes) =>
    clock.elapse(Duration(minutes: minutes));

void main() {
  test('digital silence with a running capture never restarts or switches', () {
    fakeAsync((clock) {
      final rig = _Rig();
      rig.mic.level = kInputFloorDb;
      _join(clock, chosen: _usb, rig: rig);
      _minutes(clock, 10);

      expect(rig.mic.restartDevices, isEmpty);
      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.micStatus, MicStatus.ok);
      expect(rig.session.micFallbackNotice, isNull);
    });
  });

  test('a capture that stands still is told to the user, never switched', () {
    fakeAsync((clock) {
      final rig = _Rig();
      _join(clock, chosen: _usb, rig: rig);
      rig.mic.stalled.addAll({'usb', ''});
      rig.mic.closed.add('usb');
      _minutes(clock, 10);

      expect(rig.session.micStatus, MicStatus.unavailable);
      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.micFallbackNotice, isNull);
      expect(rig.mic.restartDevices.whereType<String>(), isEmpty);
    });
  });

  test(
      'a stalled capture that survives every restart never starts the fallback',
      () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.mic.stalled.addAll({'usb', ''});
      _minutes(clock, 10);

      expect(rig.session.micStatus, MicStatus.unavailable);
      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.micFallbackNotice, isNull);
      expect(rig.logs, isNot(contains(startsWith('Switching microphone'))));
    });
  });

  test(
      'an unplugged mic whose default will not open falls to the next real mic',
      () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

      expect(rig.session.audioInputInUse, 'desk');
      expect(rig.session.micFallbackNotice, 'Desk mic');
      expect(rig.session.micStatus, MicStatus.ok);
      expect(
        rig.logs,
        contains('Switching microphone to Desk mic for this call only'),
      );
    });
  });

  test('a candidate that opens but never captures moves on to the next', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.mic.stalled.add('desk');
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

      expect(rig.session.audioInputInUse, 'son');
      expect(rig.logs, contains('Microphone Desk mic is not capturing either'));
    });
  });

  test('a silent candidate that captures is kept', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.mic.level = kInputFloorDb;
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

      expect(rig.session.audioInputInUse, 'desk');
      expect(rig.session.micStatus, MicStatus.ok);
    });
  });

  test('every candidate is tried once and then the mic stays unavailable', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.unplug('usb', alsoClosed: {'', 'desk', 'son'});
      _minutes(clock, 10);

      expect(rig.session.micStatus, MicStatus.unavailable);
      expect(rig.session.micFailure, MicFailureReason.stalled);
      expect(rig.session.micFallbackNotice, isNull);
      expect(
        rig.logs.where((l) => l.startsWith('Switching microphone to Desk')),
        hasLength(1),
      );
    });
  });

  test('a second vanished mic never goes back to a device already tried', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);
      expect(rig.session.audioInputInUse, 'desk');

      rig.unplug('desk');
      _minutes(clock, 1);

      expect(rig.session.audioInputInUse, 'son');
      expect(rig.mic.restartDevices, isNot(contains('usb')));
    });
  });

  test('with the setting off nothing is switched', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb, enabled: false);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

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
      _join(clock, chosen: _usb, output: other, rig: rig);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

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
      _join(clock, chosen: _usb, output: other, rig: rig);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);
      expect(rig.session.audioInputInUse, 'desk');

      unawaited(rig.session.leave());
      clock.flushMicrotasks();

      expect(rig.session.audioInputInUse, 'usb');
      expect(rig.session.audioOutputInUse, 'hp');
    });
  });

  test('the fallback is kept through a device change while it is plugged in',
      () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);
      expect(rig.session.audioInputInUse, 'desk');

      rig.devices.changes.add(null);
      clock.elapse(const Duration(seconds: 5));

      expect(rig.session.audioInputInUse, 'desk');
    });
  });

  test('the devices and the microphone list reach the log', () {
    fakeAsync((clock) {
      final rig = _join(clock, chosen: _usb);
      rig.unplug('usb', alsoClosed: {''});
      _minutes(clock, 1);

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
