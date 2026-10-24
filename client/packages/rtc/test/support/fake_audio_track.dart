// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A remote audio track that holds what was pushed to it, for the local audio suites.
library;

import 'package:slimm_rtc/rtc.dart';

/// One remote audio track that really does hold what was pushed to it.
///
/// [key] is a plain `Object`, standing in for the platform track that
/// [LocalAudioRef.track] carries in production. Replacing it is how a test
/// says "this track resubscribed": that is precisely what LiveKit does, since
/// `addSubscribedMediaTrack` builds a new `MediaStreamTrack` every time.
class FakeAudioTrack {
  FakeAudioTrack(this.identity, {this.channel = LocalAudioChannel.voice});

  final String identity;
  final LocalAudioChannel channel;
  Object key = Object();

  /// The platform track id; a replaced receiver may change it.
  late String nativeId = identity;

  bool enabled = true;
  double volume = kDefaultParticipantVolume;

  /// LiveKit's own `Track._active`. `enable()` and `disable()` check it and
  /// do nothing at all when it is false, silently and without throwing, so a
  /// caller cannot tell a push that landed from one that was dropped.
  bool active = true;

  /// What the SFU was last told about this publication.
  bool forwarding = true;
  int forwardCalls = 0;

  int enableCalls = 0;
  int disableCalls = 0;
  int volumeCalls = 0;

  /// How many gain pushes still fail before one lands, like a native track
  /// the platform cannot find yet.
  int failVolumeTimes = 0;

  /// Set to make the next push fail the way a real platform call can.
  Object? failure;

  int get platformCalls =>
      enableCalls + disableCalls + volumeCalls + forwardCalls;

  /// A resubscribe: same participant, same publication, new platform object
  /// arriving back at the source default with nothing to announce it.
  void resubscribe() {
    key = Object();
    enabled = true;
    volume = kDefaultParticipantVolume;
  }

  /// The native receiver replaced behind the very same Dart object and id,
  /// which nothing about the object itself gives away.
  void replaceNativeKeepingObject() {
    enabled = true;
    volume = kDefaultParticipantVolume;
  }

  /// The first half of a real resubscribe, stopping where the room event is
  /// delivered: `addSubscribedMediaTrack` swaps the publication's track and
  /// emits `TrackSubscribedEvent` before it awaits `track.start()`, and the
  /// emitter is asynchronous, so a listener runs while the new track is still
  /// inactive.
  void resubscribeButNotYetStarted() {
    resubscribe();
    active = false;
  }

  /// The rest of it. `Track.start()` awaits `startCapture()` before setting
  /// `_active`, and `RemoteTrack.start()` then calls `enable()` itself, so the
  /// track comes back audible whatever was pushed to it while it was inactive.
  void finishStarting() {
    active = true;
    enabled = true;
  }

  LocalAudioRef get ref => (
        identity: identity,
        channel: channel,
        trackId: nativeId,
        track: key,
        isAudible: () => enabled,
        enable: () async {
          enableCalls++;
          if (failure != null) throw failure!;
          if (active) enabled = true;
        },
        disable: () async {
          disableCalls++;
          if (failure != null) throw failure!;
          if (active) enabled = false;
        },
        startForwarding: () async {
          forwardCalls++;
          forwarding = true;
        },
        stopForwarding: () async {
          forwardCalls++;
          forwarding = false;
        },
        setVolume: (value) async {
          volumeCalls++;
          if (failure != null) return failure;
          if (failVolumeTimes > 0) {
            failVolumeTimes--;
            return StateError('track not found');
          }
          volume = value;
          return null;
        },
      );
}

/// Drives the state the way the room-event listener does: repeatedly, with
/// nothing having changed in between.
Future<void> pumpAudioEvents(
  LocalAudioState state,
  List<FakeAudioTrack> tracks, {
  int times = 1,
}) async {
  for (var i = 0; i < times; i++) {
    await state.applyToRefs(tracks.map((t) => t.ref));
  }
}
