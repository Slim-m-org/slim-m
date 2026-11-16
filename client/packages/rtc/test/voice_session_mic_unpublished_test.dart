// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A microphone the person wants on that has no publication, and nothing
/// publishing one, is published again: livekit drops it without an event when
/// a republish after a full restart fails.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_test_support/slimm_test_support.dart' show pollUntil;

import 'support/no_audio_devices.dart';
import 'support/session_fakes.dart';

class _Room extends ConnectlessRoom {
  void emit(lk.RoomEvent event) => events.streamCtrl.add(event);
}

class _Mic implements MicPort {
  bool published = false;
  bool muted = true;
  int enables = 0;
  int enableFailures = 0;
  final _lost = StreamController<void>.broadcast();

  /// How long a publish takes, for a test that looks at the call meanwhile.
  Duration? enableDelay;

  @override
  bool get hasTrack => published;

  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    final delay = enableDelay;
    if (enabled && delay != null) await Future<void>.delayed(delay);
    if (enabled && enableFailures > 0) {
      enableFailures--;
      throw StateError('no capture device');
    }
    if (enabled) enables++;
    published = true;
    muted = !enabled;
  }

  /// What livekit does when the capture ends underneath the call.
  void end() {
    published = false;
    _lost.add(null);
  }

  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<double?> capturedSeconds() async => null;
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
}

const _timing = MicRecoveryTiming(
  retryBase: Duration(milliseconds: 10),
  maxRetryDelay: Duration(milliseconds: 20),
  maxRetries: 3,
  captureProbe: Duration(milliseconds: 5),
);

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 250));

void main() {
  late _Mic mic;
  late _Room room;
  late VoiceSession session;
  late List<MicStatus> statuses;

  setUp(() {
    mic = _Mic();
    room = _Room();
    statuses = [];
    session = VoiceSession(
      roomFactory: () => room,
      micPort: mic,
      audioDevices: const NoAudioDevices(),
      micRecoveryTiming: _timing,
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    session.micStatuses.listen(statuses.add);
  });

  Future<void> join({bool micOn = true}) => session.join(
        url: 'wss://a.invalid',
        token: 't',
        microphoneEnabled: micOn,
      );

  test('a publication that vanished with no event is published again',
      () async {
    await join();
    expect(mic.enables, 1);

    mic.published = false;
    await pollUntil(() => mic.enables == 2);
    await pollUntil(() => session.micStatus == MicStatus.ok);

    expect(mic.open, isTrue);
    expect(statuses, [MicStatus.reconnecting, MicStatus.ok]);
  });

  test('a publish still in flight is not taken for a lost publication',
      () async {
    await join(micOn: false);
    mic.enableDelay = const Duration(milliseconds: 150);

    expect(await session.setMicrophoneEnabled(true), isTrue);
    await _settle();

    expect(mic.enables, 1);
    expect(statuses, isEmpty);
  });

  test('a microphone recovery gave up on is not retried behind its back',
      () async {
    await join();
    mic.enableFailures = 1000;

    mic.end();
    await pollUntil(() => session.micStatus == MicStatus.unavailable);
    await _settle();

    expect(statuses, [MicStatus.reconnecting, MicStatus.unavailable]);
  });

  test('a microphone a full restart is still republishing is left to livekit',
      () async {
    await join();
    room.emit(const lk.RoomReconnectingEvent());
    mic.published = false;
    await _settle();

    expect(mic.enables, 1,
        reason: 'a publish of its own would leave two microphones live');
    expect(statuses, isEmpty);

    mic.published = true;
    room.emit(const lk.RoomReconnectedEvent());
    await _settle();

    expect(mic.enables, 1);
    expect(statuses, isEmpty);
  });

  test('a restart that never reports its end brings the microphone back',
      () async {
    await join();
    room.emit(const lk.RoomReconnectingEvent());
    mic.published = false;
    await _settle();

    session.health.reconnect.ended('no reconnect event');
    await pollUntil(() => mic.enables == 2);

    expect(mic.open, isTrue);
  });

  test('a muted microphone with no publication is left alone', () async {
    await join();
    await session.setMicrophoneEnabled(false);

    mic.published = false;
    await _settle();

    expect(mic.enables, 1);
    expect(statuses, isEmpty);
  });
}
