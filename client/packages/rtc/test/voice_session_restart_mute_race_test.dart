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

void main() {
  test('a mute that lands during a capture restart lets the new capture go',
      () async {
    final mic = _SlowRestartMic();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      audioDevices: NoDevices(),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
    expect(mic.capturing, isTrue);

    mic.restartGate = Completer<void>();
    final restarting = session.resetMicrophone();
    await pumpEventQueue();
    expect(await session.setMicrophoneEnabled(false), isTrue);
    mic.restartGate!.complete();
    await restarting;
    await pumpEventQueue();

    expect(mic.muted, isTrue);
    expect(mic.capturing, isFalse,
        reason: 'a muted publication must not be left with a live capture');
  });

  test('a restart nobody muted keeps its capture', () async {
    final mic = _SlowRestartMic();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      audioDevices: NoDevices(),
      inputGate: InputGateMonitor.disabled(),
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');

    expect(await session.resetMicrophone(), isTrue);

    expect(mic.capturing, isTrue);
    expect(mic.releases, 0);
  });
}
