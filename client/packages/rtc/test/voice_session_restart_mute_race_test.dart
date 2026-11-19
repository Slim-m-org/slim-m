// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A capture restart that a mute overtakes ends with the capture let go:
/// the restart opens a fresh, live capture, and the mute already landed on
/// the publication, so nothing else would ever close it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

/// A published microphone whose capture restart waits on [restartGate].
class _SlowRestartMic implements MicPort {
  Completer<void>? restartGate;
  bool muted = false;
  bool capturing = false;
  int releases = 0;

  @override
  bool get hasTrack => true;

  @override
  bool get open => !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    muted = !enabled;
    if (enabled) capturing = true;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {
    await restartGate?.future;
    capturing = true;
  }

  @override
  Future<void> release() async {
    releases++;
    capturing = false;
  }

  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<double?> capturedSeconds() async => null;
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
  @override
  Future<void> stopUnpublished() async {}
}

Future<VoiceSession> _joined(
  _SlowRestartMic mic, {
  bool mobile = false,
  Duration grace = kMicReleaseGrace,
}) async {
  final session = VoiceSession(
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    audioDevices: NoDevices(),
    inputGate: InputGateMonitor.disabled(),
    mobile: mobile,
    micReleaseGrace: grace,
  );
  addTearDown(session.dispose);
  await session.join(url: 'wss://a.invalid', token: 't');
  return session;
}

/// Restarts the capture and mutes while the restart is still opening it.
Future<void> _muteDuringRestart(
    VoiceSession session, _SlowRestartMic mic) async {
  mic.restartGate = Completer<void>();
  final restarting = session.resetMicrophone();
  await pumpEventQueue();
  expect(await session.setMicrophoneEnabled(false), isTrue);
  await pumpEventQueue();
  mic.restartGate!.complete();
  await restarting;
  await pumpEventQueue();
}

void main() {
  test('a mute that lands during a capture restart lets the new capture go',
      () async {
    final mic = _SlowRestartMic();
    final session = await _joined(mic);
    expect(mic.capturing, isTrue);

    await _muteDuringRestart(session, mic);

    expect(mic.muted, isTrue);
    expect(mic.capturing, isFalse,
        reason: 'a muted publication must not be left with a live capture');
  });

  test(
      'a phone muted in the background during a capture restart lets the '
      'new capture go', () async {
    final mic = _SlowRestartMic();
    final session = await _joined(mic, mobile: true);
    session.setAppBackgrounded(true);

    await _muteDuringRestart(session, mic);

    expect(mic.releases, 2, reason: "the mute's own release ran first");
    expect(mic.capturing, isFalse,
        reason: 'the restart reopened the mic after the mute released it');
  });

  test('a restart that outlasts the release grace lets the new capture go',
      () async {
    final mic = _SlowRestartMic();
    final session = await _joined(mic, grace: Duration.zero);

    await _muteDuringRestart(session, mic);

    expect(mic.capturing, isFalse);
  });

  test('push to talk keeps the capture a restart reopened under a key up',
      () async {
    final mic = _SlowRestartMic();
    final session = await _joined(mic);
    await session.setKeepMicReady(true);

    await _muteDuringRestart(session, mic);

    expect(mic.muted, isTrue);
    expect(mic.capturing, isTrue,
        reason: 'push to talk keeps the device open for an instant key down');
    expect(mic.releases, 0);
  });

  test('a restart nobody muted keeps its capture', () async {
    final mic = _SlowRestartMic();
    final session = await _joined(mic);

    expect(await session.resetMicrophone(), isTrue);

    expect(mic.capturing, isTrue);
    expect(mic.releases, 0);
  });
}
