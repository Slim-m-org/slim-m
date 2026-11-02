// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Doubles for driving a [VoiceSession] through a join without a server.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/voice_log.dart';

class _Me extends Fake implements lk.LocalParticipant {
  _Me(this.identity, this.videos);

  @override
  final String identity;

  final List<lk.LocalTrackPublication<lk.LocalVideoTrack>> videos;

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
      get videoTrackPublications => videos;

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

/// A room that never reaches a server.
///
/// Its disconnect returns at once: livekit's waits 10 s for an engine event a room that never connected cannot send.
class ConnectlessRoom extends lk.Room {
  @override
  Future<void> connect(
    String url,
    String token, {
    lk.ConnectOptions? connectOptions,
    lk.RoomOptions? roomOptions,
    lk.FastConnectOptions? fastConnectOptions,
  }) async {}

  @override
  Future<void> disconnect() async {}
}

/// A room whose connect returns at once and whose local identity is [me].
class InstantRoom extends ConnectlessRoom {
  InstantRoom({
    this.me = 'me',
    List<lk.LocalTrackPublication<lk.LocalVideoTrack>>? videos,
  }) : videos = videos ?? [];

  final String me;

  /// The video the local participant publishes; a test mutates it between events.
  final List<lk.LocalTrackPublication<lk.LocalVideoTrack>> videos;

  @override
  lk.LocalParticipant? get localParticipant => _Me(me, videos);
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
  InstantRoom? room,
  VoiceLog? audioLog,
}) =>
    VoiceSession(
      roomFactory: () => room ?? InstantRoom(me: me),
      audioLog: audioLog,
      micPort: mic,
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      joinTimings: timings,
      inputGate: InputGateMonitor.disabled(),
    );
