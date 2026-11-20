// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A capture the last call let go while muted says nothing about the next
/// call's microphone, which starts open and unmuted.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

/// A published microphone that records the options of every open.
class _RecordingMic implements MicPort {
  final opens = <lk.AudioCaptureOptions?>[];
  bool muted = false;
  int releases = 0;

  @override
  bool get hasTrack => true;

  @override
  bool get open => !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    muted = !enabled;
    if (enabled) opens.add(options);
  }

  @override
  Future<void> release() async => releases++;

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {}
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
  test('a mic released in the last call opens plainly in the next one',
      () async {
    final mic = _RecordingMic();
    final session = VoiceSession(
      roomFactory: ConnectlessRoom.new,
      micPort: mic,
      audioDevices: NoDevices(),
      inputGate: InputGateMonitor.disabled(),
      micReleaseGrace: Duration.zero,
    );
    addTearDown(session.dispose);
    await session.join(url: 'wss://a.invalid', token: 't');
    expect(await session.setMicrophoneEnabled(false), isTrue);
    await pumpEventQueue();
    expect(mic.releases, 1, reason: 'the muted capture was let go');

    await session.leave();
    await session.join(
        url: 'wss://a.invalid', token: 't', microphoneEnabled: false);
    mic.opens.clear();
    expect(await session.setMicrophoneEnabled(true), isTrue);

    expect(mic.opens.single?.stopAudioCaptureOnMute, isFalse,
        reason: 'a new call has nothing released to reopen');
  });
}
