// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The lifecycle of a voice call: join, leave, the room's events and the
/// teardown every call-ending path runs.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart'
    show AppLog, LogTag, ignoreError, reportFailure;

import 'audio_event_scope.dart';
import 'audio_gain.dart' as rtc_gain;
import 'join_timings.dart';
import 'voice_disconnect_reason.dart';
import 'voice_first_audio.dart';
import 'voice_models.dart';
import 'voice_reconnect_tracker.dart';
import 'voice_roster_snapshot.dart';
import 'voice_session_core.dart';

/// Owns the room, the call's state and its generation, and orders the
/// teardown; every other part of the call is reached through [VoiceSessionCore].
class VoiceCallFlow {
  VoiceCallFlow(this._core) {
    _core.healthWatch.health.reconnect
      ..log = _core.diag
      ..restarting.addListener(_onReconnectingChanged);
  }

  final VoiceSessionCore _core;
  final _states = StreamController<VoiceSessionState>.broadcast();

  /// The room of the call in progress; cleared synchronously when one ends.
  lk.Room? room;
  VoiceSessionState state = VoiceSessionState.idle;
  bool disposed = false;

  /// Why the last call ended, when the SFU ended it rather than this client.
  VoiceDisconnect? lastDisconnect;

  /// Whether the call the SFU just ended was sharing a screen, read before the roster emptied.
  bool droppedWhileSharing = false;

  // room.events.listen returns a canceller, not a StreamSubscription.
  lk.CancelListenFunc? _cancelEvents;
  void Function()? _stopArrivalWatch;

  /// The in-flight join, so a second call serializes behind it; see [join].
  Future<void>? _joining;

  /// Bumped by every join and every leave, so a teardown still unwinding can
  /// tell that a newer call has taken this session over; see [leave].
  int _generation = 0;

  Stream<VoiceSessionState> get states => _states.stream;

  /// Joins a room with a server-minted token; [canPublish] only stops a listen-only join from opening the microphone, and rejoining leaves the old connection first.
  /// Overlapping calls serialize, so a second tap or a channel switch mid-connect waits and the state ends as the last caller asked.
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
    bool canPublish = true,
  }) {
    final previous = _joining ?? Future<void>.value();
    final current = previous
        .catchError(ignoreError(LogTag.voice,
            'An earlier call setup step failed; it was already reported'))
        .then(
          (_) => _join(
            url: url,
            token: token,
            microphoneEnabled: microphoneEnabled,
            cameraEnabled: cameraEnabled,
            canPublish: canPublish,
          ),
        );
    _joining = current.whenComplete(() {
      if (identical(_joining, current)) _joining = null;
    });
    return current;
  }

  /// Leaves the call and resets deafen and mutes with it. Safe to call when not in one.
  ///
  /// A leave a newer join already superseded resets nothing: [_teardown] clears `room` before it awaits.
  Future<void> leave() async {
    final generation = ++_generation;
    await _teardown();
    if (generation != _generation) return;
    _core.roster.set(const []);
    _core.listener.resetForNewCall();
    // Gain deliberately survives: somebody you turned down stays turned down.
    lastDisconnect = null;
    droppedWhileSharing = false;
    _core.video.resetForNewCall();
    _setState(VoiceSessionState.idle);
  }

  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    _core.video.dispose();
    _core.share.dispose();
    await _core.stall.dispose();
    await _core.stats.sampler.dispose();
    _core.healthWatch.health.dispose();
    _core.joinTimings.finish();
    // After `_teardown`, or its own `resetFacing()` writes past disposal.
    await _teardown();
    await _core.camera.dispose();
    await _core.micGate.dispose();
    await _core.micRecovery.dispose();
    await _core.micGate.gate.dispose();
    await _core.roster.dispose();
    await _states.close();
  }

  Future<void> _join({
    required String url,
    required String token,
    required bool microphoneEnabled,
    required bool cameraEnabled,
    required bool canPublish,
  }) async {
    if (disposed) return;
    _core.readiness.mayPublish = canPublish;
    if (room != null) await leave();
    // Claims the session past the leave above, whose own guard has run by now.
    _generation++;
    // A leave this join superseded never reached idle, which is what ends the old call's health.
    _core.healthWatch.glitchWatch.finish();

    lastDisconnect = null;
    droppedWhileSharing = false;
    _setState(VoiceSessionState.connecting);
    final generation = _generation;
    await _core.devices.forgetUnplugged();
    if (disposed || generation != _generation) return;
    final joining = _core.createRoom();
    room = joining;
    _listen(joining);
    _core.setupLog.start();
    try {
      _core.joinTimings.mark(JoinStage.connectStarted);
      await joining.connect(url, token);
      // A leave or newer join took this room mid-connect and tore it down.
      if (!identical(room, joining)) return;
      _core.joinTimings.mark(JoinStage.connected);
      // Apart from the connect: a muted preview or a token without SPEAK must not fail the join.
      final micFailed =
          microphoneEnabled && !await _core.micRecovery.setEnabled(true);
      if (!identical(room, joining)) return;
      _core.refresh();
      _setState(VoiceSessionState.connected);
      // A slow webcam must not hold "connected" back; see CameraJoin.
      if (cameraEnabled) {
        unawaited(
          _core.camera.openAfterJoin(
            joining,
            current: () =>
                !disposed &&
                identical(room, joining) &&
                generation == _generation,
            held: () => !disposed && identical(room, joining),
          ),
        );
      }
      if (micFailed) _core.micRecovery.retryAfterJoin();
      if (!microphoneEnabled) await _core.readiness.primeMuted();
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'join the call', e, stack);
      if (!identical(room, joining)) return;
      _core.lastError = e;
      _core.joinTimings.finish();
      await _teardown();
      _setState(VoiceSessionState.failed);
    }
  }

  /// One coarse listener rather than a subscription per event type. Every
  /// event this cares about ends in the same place, "recompute who is in the
  /// call and what they are doing", so an event LiveKit adds later is picked
  /// up rather than silently ignored.
  void _listen(lk.Room joining) {
    final audio = _core.listener.audio;
    _cancelEvents?.call();
    _stopArrivalWatch?.call();
    _stopArrivalWatch = rtc_gain.watchAudioArrivals(
      (trackId) => audio.holdArrival(
          audio.refsOf(joining), trackId, rtc_gain.holdArrivedAudio),
    );
    _cancelEvents = joining.events.listen((event) {
      _noteTransport(event);
      _core.mic.onRoomEvent(event);
      final replaced = audioReplacedBy(event);
      if (replaced != null) audio.trackReplaced(replaced);
      if (event is lk.TrackSubscribedEvent &&
          event.track is lk.RemoteAudioTrack &&
          event.publication.source == lk.TrackSource.microphone) {
        unawaited(_watchFirstRemoteAudio(event.track as lk.RemoteAudioTrack));
      }
      if (event is lk.LocalTrackUnpublishedEvent &&
          event.publication.source == lk.TrackSource.screenShareVideo &&
          !isSharingScreen(joining.localParticipant)) {
        unawaited(_core.share.control.shareEnded());
      }
      if (event is lk.RoomDisconnectedEvent) {
        return _onDisconnected(event.reason);
      }
      _core.stats.syncHold();
      _core.refresh();
    });
  }

  /// Marks the first remote audio, once a subscribed track has delivered a packet.
  Future<void> _watchFirstRemoteAudio(lk.RemoteAudioTrack track) {
    final watched = room;
    return watchFirstAudio(
      joinOpen: () =>
          watched != null &&
          identical(room, watched) &&
          _core.joinTimings.isOpen,
      packetsReceived: () async =>
          (await track.getReceiverStats())?.packetsReceived,
      onAudio: () => _core.joinTimings.mark(JoinStage.firstRemoteAudio),
    );
  }

  /// Folds the SDK's reconnect events into [VoiceHealth.reconnect]; observation only.
  void _noteTransport(lk.RoomEvent event) {
    final tracker = _core.healthWatch.health.reconnect;
    switch (event) {
      case lk.RoomReconnectingEvent():
        tracker.started(ReconnectKind.restart);
      case lk.RoomResumingEvent():
        tracker.started(ReconnectKind.resume);
      case lk.RoomAttemptReconnectEvent():
        tracker.attempted(
          event.attempt,
          event.maxAttemptsRetry,
          event.nextRetryDelaysInMs,
        );
      case lk.RoomReconnectedEvent():
        tracker.ended('reconnected');
      default:
    }
  }

  /// Pauses what a half-repaired transport would only mislead, and rebuilds the roster from the live room once it is back.
  void _onReconnectingChanged() {
    if (disposed) return;
    if (_core.healthWatch.health.reconnect.restarting.value) {
      _core.healthWatch.stop();
      // Tracks are forgotten so the grace period starts again once frames can flow.
      _core.stall.watchdog.observe(const []);
      return;
    }
    if (room == null || state != VoiceSessionState.connected) return;
    _core.healthWatch.glitchWatch.start();
    _core.refresh();
  }

  /// A disconnect this client did not ask for: the SFU removed this
  /// participant, the room was deleted, or the connection was lost for good.
  /// `_teardown` cancels this listener before it disconnects, so a `leave()`
  /// never lands here.
  ///
  /// LiveKit's own engine already unpublishes and stops every local track for
  /// this case (`Room`'s internal cleanup runs on any engine disconnect, not
  /// only a client-initiated one), but that stops at the WebRTC track: it
  /// never asks iOS to end a running broadcast, which is a platform-level
  /// concept LiveKit has no reason to know about. By the time this fires the
  /// SFU has already disconnected, so this is the only remaining chance to
  /// tell iOS to stop, and it is awaited before anything else this handler
  /// does rather than fired into the background: a member removed or timed
  /// out mid-share must not keep recording with no call left to publish to.
  Future<void> _onDisconnected(lk.DisconnectReason? reason) async {
    if (disposed) return;
    if (reason == lk.DisconnectReason.clientInitiated) {
      _core.healthWatch.health.reconnect.ended('disconnected');
      return;
    }
    // Read from the last roster, before the empty one below erases it.
    droppedWhileSharing =
        _core.roster.participants.any((p) => p.isLocal && p.isScreenSharing);
    _core.listener.audio.cancelRetry();
    await _core.share.control.stopActiveBroadcast();
    lastDisconnect = mapDisconnectReason(reason);
    _core.roster.set(const []);
    // Ends any open blip through the health summary, with the state already failed.
    _setState(VoiceSessionState.failed);
    await _core.share.control.dispose();
  }

  /// Drops this session's room, and everything holding it open, in the order
  /// a call has to end in. Every path that ends a call runs this: [leave], a
  /// [join] replacing a room that is still up, and [dispose].
  ///
  /// `room` is cleared before anything else, and synchronously: a join
  /// racing this teardown reads it to tell whether it is still the current
  /// attempt, and that answer has to be final the instant a teardown starts.
  ///
  /// The room event listener's own cancellation is awaited before the room
  /// disconnects below: a straggling `RoomDisconnectedEvent` on an
  /// uncancelled listener would still reach `_onDisconnected` mid-teardown,
  /// which `_onDisconnected`'s own doc says a `leave()` must never do.
  Future<void> _teardown() async {
    _core.listener.audio.cancelRetry();
    _core.listener.audio.trackReplaced(everyone);
    _core.roster.cancelHold();
    // Synchronously, and before anything else; see this method's own doc.
    final leaving = room;
    room = null;
    _core.healthWatch.health.reconnect.ended('left the call');
    _core.camera.cancelJoin();
    _core.stall.stop();
    _core.stats.release();
    _core.micRecovery.stopWatch();
    _core.healthWatch.stop();
    _core.setupLog.stop();
    _core.micGate.strong.reset();
    _stopArrivalWatch?.call();
    _stopArrivalWatch = null;
    final cancelEvents = _cancelEvents;
    _cancelEvents = null;
    if (cancelEvents != null) await _step(cancelEvents);
    // Not every call-ending path resets it; this one covers all of them.
    _core.camera.switching.resetFacing();
    _core.share.watch.stop();
    // Awaited before the room disconnects below: the SFU has no bearing on iOS.
    await _step(_core.share.control.stopActiveBroadcast);
    await _step(_core.share.control.dispose);
    if (leaving != null) {
      await _step(leaving.disconnect);
      await _step(leaving.dispose);
    }
  }

  void _setState(VoiceSessionState next) {
    if (state == next || disposed) return;
    state = next;
    _core.micRecovery.syncWatch(next);
    _core.healthWatch.sync(next);
    _core.stats.syncDiagnostics(next);
    final gate = _core.micGate;
    if (next == VoiceSessionState.connected) {
      unawaited(gate.apply());
      gate.applyRate();
      gate.gate.start(_core.refresh);
    } else {
      gate.gate.stop();
    }
    if (!_states.isClosed) _states.add(next);
  }
}

/// Runs one teardown step, absorbing its failure so it cannot abandon the
/// steps after it.
///
/// Hanging up has to reach the room disconnect whatever a platform said about
/// a broadcast it was already asked to stop, and has to reach the room
/// dispose whatever the disconnect said - a room already gone is the state
/// this wanted anyway. Before this, only `disconnect` was guarded, so a throw
/// from either step ahead of it left the room connected,
/// [VoiceCallFlow.leave] throwing rather than settling, and whatever the
/// caller resets on a hang-up unreached - which reads on screen as a hang-up
/// that did nothing.
///
/// Deliberately does not record the failure as the session's last error: that
/// field is what a join, camera or share failure turns into visible copy, and
/// a teardown has no caller left that could act on one.
Future<void> _step(Future<void> Function() run) async {
  try {
    await run();
  } catch (error, stack) {
    AppLog.swallowed(LogTag.voice,
        'A call cleanup step failed; carrying on with the rest', error, stack);
    // See this function's own doc comment for why nothing is kept.
  }
}
