// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Doubles for driving a [VoiceSession] through a join without a server.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Me extends Fake implements lk.LocalParticipant {
  _Me(this.identity);

  @override
  final String identity;

  @override
  String get name => '';

  @override
  bool get isSpeaking => false;

  @override
  double get audioLevel => 0;

  @override
  UnmodifiableMapView<String, String> get attributes => UnmodifiableMapView({});

  @override
  List<lk.LocalTrackPublication<lk.LocalVideoTrack>>
      get videoTrackPublications => const [];

  @override
  List<lk.LocalTrackPublication<lk.LocalAudioTrack>>
      get audioTrackPublications => const [];

  @override
  Future<void> unpublishAllTracks({
    bool notify = true,
    bool? stopOnUnpublish,
  }) async {}

  @override
  Future<bool> dispose() async => true;
}

/// A room whose connect returns at once and whose local identity is [me].
class InstantRoom extends lk.Room {
  InstantRoom({this.me = 'me'});

  final String me;

  @override
  lk.LocalParticipant? get localParticipant => _Me(me);

  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}
}

/// A microphone that counts how often the capture is opened muted.
class CountingMic implements MicPort {
  int reopens = 0;
  bool hasTrackNow = false;

  @override
  bool get hasTrack => hasTrackNow;
  @override
  bool get open => hasTrackNow;
  @override
  Future<double?> senderLevelDb() async => null;
  @override
  Future<void> setEnabled(bool enabled, lk.AudioCaptureOptions? options) async {
    hasTrackNow = enabled;
  }

  @override
  Future<void> restart(lk.AudioCaptureOptions options) async {}
  @override
  Future<void> release() async {}
  @override
  Future<void> reopenMuted(lk.AudioCaptureOptions options) async {
    reopens++;
    hasTrackNow = true;
  }

  @override
  void adoptOptions(lk.AudioCaptureOptions options) {}
  @override
  Stream<void> get lost => const Stream.empty();
  @override
  void onRoomEvent(lk.RoomEvent event) {}
  @override
  Future<void> discard() async {}
}

class NoDevices implements AudioDevices {
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

VoiceSession instantSession({
  required CountingMic mic,
  JoinTimings? timings,
  String me = 'me',
}) =>
    VoiceSession(
      roomFactory: () => InstantRoom(me: me),
      micPort: mic,
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      joinTimings: timings,
      inputGate: InputGateMonitor.disabled(),
    );
