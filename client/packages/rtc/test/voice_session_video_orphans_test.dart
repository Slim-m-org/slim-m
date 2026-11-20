// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera or screen track livekit left capturing with no publication is
/// stopped: a full restart clears the publications and republishes them one
/// at a time, and one that throws ends the rest, which left the camera light
/// on with the call showing it off, even after leaving.
library;

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_rtc/src/video_orphans.dart';
import 'package:slimm_rtc/src/voice_call_flow.dart' show kJoinWaitsForLeave;

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

/// A room whose dispose waits on [disposeGate], the leave that outlasts a rejoin's wait.
class _HungRoom extends PeopleRoom {
  _HungRoom(this.disposeGate);

  final Future<void> disposeGate;

  @override
  Future<bool> dispose() async {
    await disposeGate;
    return super.dispose();
  }
}

/// Publishes a track in [room] the way livekit announces one.
_Track _announce(PeopleRoom room, lk.TrackSource source) {
  final track = _Track(source);
  final publication = _Published(track);
  room.videos.add(publication);
  room.emit(lk.LocalTrackPublishedEvent(
    participant: room.localParticipant!,
    publication: publication,
  ));
  return track;
}

/// Runs what livekit queued on the real event loop (its listener cancel
/// completes there), then what that queued on [clock].
Future<void> _settle(FakeAsync clock) async {
  for (var i = 0; i < 20; i++) {
    await Future<void>.delayed(Duration.zero);
    clock.flushMicrotasks();
  }
}

VoiceSession _session(lk.Room Function() rooms) => VoiceSession(
      roomFactory: rooms,
      micPort: CountingMic(),
      audioDevices: NoDevices(),
      liveOutput: (room, device) async {},
      inputGate: InputGateMonitor.disabled(),
    );

class _Call {
  _Call() {
    session = _session(() => room);
  }

  final room = PeopleRoom();
  late final VoiceSession session;

  Future<void> join() => session.join(url: 'wss://a.invalid', token: 't');

  Future<_Track> publish(lk.TrackSource source) async {
    final track = _announce(room, source);
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

  test('a camera turned off and on is not remembered once stopped', () {
    final room = PeopleRoom();
    final orphans = VideoOrphans();
    void publish(_Track track) => orphans.onRoomEvent(
          lk.LocalTrackPublishedEvent(
            participant: room.localParticipant!,
            publication: _Published(track),
          ),
        );
    final first = _Track(lk.TrackSource.camera);
    publish(first);
    first.capturing = false;
    final second = _Track(lk.TrackSource.camera);
    publish(second);

    expect(orphans.takeAll(), [second]);
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

  test(
      'a leave that finishes after a rejoin took over stops only its own '
      "call's video", () async {
    final clock = FakeAsync();
    final hung = Completer<void>();
    final old = _HungRoom(hung.future);
    final next = PeopleRoom();
    var built = 0;
    final session = _session(() => ++built == 1 ? old : next);
    addTearDown(session.dispose);
    unawaited(
        clock.run((_) => session.join(url: 'wss://a.invalid', token: 't1')));
    await _settle(clock);
    final orphan = clock.run((_) => _announce(old, lk.TrackSource.camera));
    await _settle(clock);
    old.videos.clear();

    clock.run((_) {
      session.leave();
      session.join(url: 'wss://a.invalid', token: 't2');
    });
    await _settle(clock);
    clock.elapse(kJoinWaitsForLeave + const Duration(milliseconds: 1));
    await _settle(clock);
    expect(session.state, VoiceSessionState.connected);
    final camera = clock.run((_) => _announce(next, lk.TrackSource.camera));
    final screen =
        clock.run((_) => _announce(next, lk.TrackSource.screenShareVideo));
    await _settle(clock);
    expect(orphan.capturing, isTrue,
        reason: 'the old teardown is still held at its room dispose');

    hung.complete();
    await _settle(clock);

    expect(orphan.capturing, isFalse);
    expect(camera.capturing, isTrue,
        reason: 'the late teardown froze the camera of the call that '
            'replaced it, with the publication still up');
    expect(screen.capturing, isTrue);
    expect(session.state, VoiceSessionState.connected);
  });
}
