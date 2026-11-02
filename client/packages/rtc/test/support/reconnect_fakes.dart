// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A room whose remote people can be added and removed, for the reconnect suites.
library;

import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show LogLevel;
import 'package:slimm_rtc/rtc.dart';

import 'session_fakes.dart';

/// A subscribed, playing camera that counts how often its quality was set.
class FakeCameraPublication extends Fake
    implements lk.RemoteTrackPublication<lk.RemoteVideoTrack> {
  int qualityCalls = 0;

  @override
  String get sid => 'camera-sid';

  @override
  lk.TrackSource get source => lk.TrackSource.camera;

  @override
  bool get subscribed => true;

  @override
  bool get muted => false;

  @override
  lk.StreamState get streamState => lk.StreamState.active;

  @override
  lk.RemoteVideoTrack? get track => null;

  @override
  Future<void> subscribe() async {}

  @override
  Future<void> unsubscribe() async {}

  @override
  Future<void> setVideoQuality(lk.VideoQuality quality) async => qualityCalls++;
}

class FakePeer extends Fake implements lk.RemoteParticipant {
  FakePeer(this.identity, {this.camera});

  @override
  final String identity;

  final FakeCameraPublication? camera;

  @override
  String get name => identity;

  @override
  bool get isSpeaking => false;

  @override
  double get audioLevel => 0;

  @override
  UnmodifiableMapView<String, String> get attributes => UnmodifiableMapView({});

  @override
  List<lk.RemoteTrackPublication<lk.RemoteAudioTrack>>
      get audioTrackPublications => const [];

  @override
  List<lk.RemoteTrackPublication<lk.RemoteVideoTrack>>
      get videoTrackPublications => [
            if (camera != null)
              camera! as lk.RemoteTrackPublication<lk.RemoteVideoTrack>
          ];
}

class PeopleRoom extends InstantRoom {
  final people = <String, lk.RemoteParticipant>{};

  @override
  UnmodifiableMapView<String, lk.RemoteParticipant> get remoteParticipants =>
      UnmodifiableMapView(people);

  void emit(lk.RoomEvent event) => events.streamCtrl.add(event);
}

/// A session in a [PeopleRoom] that has joined, with what it logged.
class JoinedCall {
  JoinedCall._(this.session, this.room, this.log);

  final VoiceSession session;
  final PeopleRoom room;
  final List<String> log;

  static Future<JoinedCall> join({
    Map<String, lk.RemoteParticipant> people = const {},
  }) async {
    final room = PeopleRoom()..people.addAll(people);
    final log = <String>[];
    final session = VoiceSession(
      roomFactory: () => room,
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
      audioLog: (line, {LogLevel level = LogLevel.info}) => log.add(line),
    );
    await session.join(url: 'wss://a.invalid', token: 't');
    return JoinedCall._(session, room, log);
  }
}
