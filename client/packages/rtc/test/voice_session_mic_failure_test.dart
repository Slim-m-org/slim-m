// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The session says why the microphone would not open, so the call can tell
/// the person what to do about it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'support/no_audio_devices.dart';

import 'support/session_fakes.dart';

class _Mic implements MicPort {
  Object? failure;
  bool published = false;
  bool muted = true;
  final _lost = StreamController<void>.broadcast();

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    final error = failure;
    if (enabled && error != null) throw error;
    published = true;
    muted = !enabled;
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
  Stream<void> get lost => _lost.stream;
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async => published = false;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 50));

(VoiceSession, _Mic) _rig({bool osBlocked = false}) {
  final mic = _Mic();
  final session = VoiceSession(
    audioDevices: const NoAudioDevices(),
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    inputGate: InputGateMonitor.disabled(),
    osMicBlocked: () async => osBlocked,
    micRecoveryTiming: const MicRecoveryTiming(
      retryBase: Duration(milliseconds: 5),
      maxRetryDelay: Duration(milliseconds: 5),
      maxRetries: 2,
    ),
  );
  addTearDown(session.dispose);
  return (session, mic);
}

Future<void> _join(VoiceSession session, {bool mic = false}) => session.join(
      url: 'wss://a.invalid',
      token: 't',
      microphoneEnabled: mic,
    );

void main() {
  test('a refused unmute names the cause, and a later success clears it',
      () async {
    final (session, mic) = _rig();
    await _join(session);
    final seen = <MicFailureReason?>[];
    session.micFailures.listen(seen.add);

    mic.failure = 'DOMException, NotAllowedError';
    expect(await session.setMicrophoneEnabled(true), isFalse);
    await _settle();
    expect(session.micFailure, MicFailureReason.permissionDenied);

    mic.failure = null;
    expect(await session.setMicrophoneEnabled(true), isTrue);
    await _settle();
    expect(session.micFailure, isNull);
    expect(seen, [MicFailureReason.permissionDenied, null]);
  });

  test('an unnamed failure is upgraded to a block when the OS reports one',
      () async {
    final (session, mic) = _rig(osBlocked: true);
    await _join(session);
    mic.failure = StateError('could not start capture');

    await session.setMicrophoneEnabled(true);
    await _settle();

    expect(session.micFailure, MicFailureReason.permissionDenied);
  });

  test('an unnamed failure stays unknown when the OS reports no block',
      () async {
    final (session, mic) = _rig();
    await _join(session);
    mic.failure = StateError('could not start capture');

    await session.setMicrophoneEnabled(true);
    await _settle();

    expect(session.micFailure, MicFailureReason.unknown);
  });

  test('a busy device is not mistaken for a block', () async {
    final (session, mic) = _rig(osBlocked: true);
    await _join(session);
    mic.failure = 'NotReadableError';

    await session.setMicrophoneEnabled(true);
    await _settle();

    expect(session.micFailure, MicFailureReason.busy);
  });
}
