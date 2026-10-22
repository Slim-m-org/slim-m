// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A muted microphone gives the capture device back after a grace period,
/// keeps it for push to talk, and reopens it on the next unmute.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/session_fakes.dart';

class _FakeMic implements MicPort {
  bool published = false;
  bool muted = true;
  bool captureOpen = false;
  int releases = 0;
  int reopens = 0;
  final calls = <(bool, bool?)>[];

  @override
  bool get hasTrack => published;
  @override
  bool get open => published && !muted;

  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    calls.add((enabled, options?.stopAudioCaptureOnMute));
    if (enabled && !captureOpen) captureOpen = true;
    published = true;
    muted = !enabled;
  }

  @override
  Future<void> release() async {
    releases++;
    captureOpen = false;
  }

  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    reopens++;
    captureOpen = true;
    published = true;
  }

  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {}
  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}
  @override
  Stream<void> get lost => const Stream.empty();
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async => published = false;
}

const _grace = Duration(seconds: 30);

Future<(VoiceSession, _FakeMic)> _joined({
  bool mobile = false,
  bool microphoneEnabled = true,
  bool pushToTalk = false,
}) async {
  final mic = _FakeMic();
  final session = VoiceSession(
    roomFactory: ConnectlessRoom.new,
    micPort: mic,
    audioDevices: _NoDevices(),
    micReleaseGrace: _grace,
    mobile: mobile,
  );
  if (pushToTalk) await session.setKeepMicReady(true);
  await session.join(
    url: 'wss://a.invalid',
    token: 't',
    microphoneEnabled: microphoneEnabled,
  );
  return (session, mic);
}

class _NoDevices implements AudioDevices {
  @override
  Future<List<AudioDevice>> inputs() async => const [];
  @override
  Future<List<AudioDevice>> outputs() async => const [];
  @override
  Future<AudioDevice?> systemDefaultInput() async => null;
  @override
  Future<AudioDevice?> systemDefaultOutput() async => null;
  @override
  Stream<void> get onChange => const Stream.empty();
}

void main() {
  test('a mute keeps the capture through the grace, then releases it', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();

      clock.elapse(_grace - const Duration(seconds: 1));
      expect(mic.releases, 0, reason: 'still inside the grace period');
      clock.elapse(const Duration(seconds: 2));
      expect(mic.releases, 1);
    });
  });

  test('an unmute inside the grace is instant and never reopens', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      clock.elapse(const Duration(seconds: 10));

      session.setMicrophoneEnabled(true);
      clock.flushMicrotasks();
      expect(mic.calls.last, (true, false), reason: 'plain unmute');
      clock.elapse(_grace * 2);
      expect(mic.releases, 0, reason: 'the timer died with the unmute');
    });
  });

  test('an unmute after the release asks the SDK to reopen the capture', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      clock.elapse(_grace + const Duration(seconds: 1));

      session.setMicrophoneEnabled(true);
      clock.flushMicrotasks();
      expect(mic.calls.last, (true, true));

      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(true);
      clock.flushMicrotasks();
      expect(mic.calls.last, (true, false), reason: 'open again, plain unmute');
    });
  });

  test('push to talk keeps the capture open however long the mute', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setKeepMicReady(true);
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      clock.elapse(_grace * 10);
      expect(mic.releases, 0);

      session.setKeepMicReady(false);
      clock.elapse(_grace + const Duration(seconds: 1));
      expect(mic.releases, 1,
          reason: 'turning push to talk off starts the clock');
    });
  });

  test('turning push to talk on reopens a released capture, muted', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      clock.elapse(_grace + const Duration(seconds: 1));
      expect(mic.captureOpen, isFalse);

      session.setKeepMicReady(true);
      clock.flushMicrotasks();
      expect(mic.reopens, 1);
      expect(mic.captureOpen, isTrue);
      session.setMicrophoneEnabled(true);
      clock.flushMicrotasks();
      expect(mic.calls.last, (true, false),
          reason: 'key down is a plain unmute');
    });
  });

  test('a phone releases a muted capture the moment it is backgrounded', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined(mobile: true).then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      clock.flushMicrotasks();
      session.setAppBackgrounded(true);
      clock.flushMicrotasks();
      expect(mic.releases, 1);
    });
  });

  test('a desktop window in the background keeps its grace period', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined().then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setMicrophoneEnabled(false);
      session.setAppBackgrounded(true);
      clock.flushMicrotasks();
      expect(mic.releases, 0);
    });
  });

  test('an unmuted microphone is never released, backgrounded or not', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined(mobile: true).then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      session.setAppBackgrounded(true);
      clock.elapse(_grace * 3);
      expect(mic.releases, 0);
    });
  });

  test('a push-to-talk call opens the device at join, so key down is plain',
      () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined(microphoneEnabled: false, pushToTalk: true)
          .then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      expect(mic.reopens, 1, reason: 'opened before the first press');
      expect(mic.captureOpen, isTrue);
      expect(mic.open, isFalse, reason: 'still muted until the key goes down');

      clock.elapse(_grace * 10);
      expect(mic.releases, 0);
      session.setMicrophoneEnabled(true);
      clock.flushMicrotasks();
      expect(mic.calls.last, (true, false));
    });
  });

  test('turning push to talk on in a call with no track opens the device', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined(microphoneEnabled: false).then((r) => (session, mic) = r);
      clock.flushMicrotasks();
      expect(mic.captureOpen, isFalse, reason: 'a muted join stays closed');

      session.setKeepMicReady(true);
      clock.flushMicrotasks();
      expect(mic.captureOpen, isTrue);
    });
  });

  test('turning push to talk off lets a ready device go after the grace', () {
    fakeAsync((clock) {
      late VoiceSession session;
      late _FakeMic mic;
      _joined(microphoneEnabled: false, pushToTalk: true)
          .then((r) => (session, mic) = r);
      clock.flushMicrotasks();

      session.setKeepMicReady(false);
      clock.elapse(_grace - const Duration(seconds: 1));
      expect(mic.captureOpen, isTrue);
      clock.elapse(const Duration(seconds: 2));
      expect(mic.captureOpen, isFalse, reason: 'the OS indicator goes off');
    });
  });
}
