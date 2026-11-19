// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera or screen track livekit left capturing with no publication is
/// stopped: a full restart clears the publications and republishes them one
/// at a time, and one that throws ends the rest, which left the camera light
/// on with the call showing it off, even after leaving.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

import 'support/reconnect_fakes.dart';
import 'support/session_fakes.dart';

class _Track extends Fake implements lk.LocalVideoTrack {
  _Track(this.source);

  @override
  final lk.TrackSource source;
  bool capturing = true;

  @override
  bool get isActive => capturing;

  @override
  rtc.RTCRtpSender? get sender => null;

  @override
  Future<bool> stop() async {
    final was = capturing;
    capturing = false;
    return was;
  }
}

class _Published extends Fake
    implements lk.LocalTrackPublication<lk.LocalVideoTrack> {
  _Published(this.track);

  @override
  final _Track track;

  @override
  lk.TrackSource get source => track.source;

  @override
  bool get muted => false;
}

class _Call {
  _Call() {
    session = VoiceSession(
      roomFactory: () => room,
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );
  }

  final room = PeopleRoom();
  late final VoiceSession session;

  Future<void> join() => session.join(url: 'wss://a.invalid', token: 't');

  /// Publishes a track the way livekit announces one.
  Future<_Track> publish(lk.TrackSource source) async {
    final track = _Track(source);
    final publication = _Published(track);
    room.videos.add(publication);
    room.emit(lk.LocalTrackPublishedEvent(
      participant: room.localParticipant!,
      publication: publication,
    ));
    await pumpEventQueue();
    return track;
  }

  /// A full restart whose republish failed: the publications are gone.
  Future<void> restartLosingPublications() async {
    room.emit(const lk.RoomReconnectingEvent());
    await pumpEventQueue();
    room.videos.clear();
    room.emit(const lk.RoomReconnectedEvent());
    await pumpEventQueue();
  }
}

void main() {
  test('a camera a full restart left unpublished is stopped once it is over',
      () async {
    final call = _Call();
    addTearDown(call.session.dispose);
    await call.join();
    final camera = await call.publish(lk.TrackSource.camera);
    final screen = await call.publish(lk.TrackSource.screenShareVideo);

    await call.restartLosingPublications();

    expect(camera.capturing, isFalse, reason: 'the camera light stayed on');
    expect(screen.capturing, isFalse);
  });

  test('a camera the restart republished keeps capturing', () async {
    final call = _Call();
    addTearDown(call.session.dispose);
    await call.join();
    final camera = await call.publish(lk.TrackSource.camera);

    call.room.emit(const lk.RoomReconnectingEvent());
    await pumpEventQueue();
    call.room.emit(const lk.RoomReconnectedEvent());
    await pumpEventQueue();

    expect(camera.capturing, isTrue);
  });

  test('leaving stops a camera left with no publication', () async {
    final call = _Call();
    addTearDown(call.session.dispose);
    await call.join();
    final camera = await call.publish(lk.TrackSource.camera);
    call.room.videos.clear();

    await call.session.leave();

    expect(camera.capturing, isFalse,
        reason: "the room's own cleanup stops only published tracks");
  });
}
