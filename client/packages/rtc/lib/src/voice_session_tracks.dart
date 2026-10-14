// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_session.dart';

/// [VoiceSession]'s private plumbing: the "try to change a published track"
/// leaves behind its microphone, camera and deafen controls, plus the room
/// event listener, the forced-disconnect handler that listener routes to,
/// and the teardown every other call-ending path runs.
///
/// Split out for the file's 500-line hard ceiling. Everything here is
/// entirely private, unlike the public callers, which stay declared on
/// [VoiceSession] itself: several tests build a `FakeSession implements
/// VoiceSession` specifically so a method added to the real session is a
/// compile error there rather than a silently untested path, and moving a
/// *public* method out of the class into an extension would drop it from
/// that interface instead of merely relocating its body.
extension VoiceSessionTracks on VoiceSession {
  /// One coarse listener rather than a subscription per event type. Every
  /// event this cares about ends in the same place, "recompute who is in the
  /// call and what they are doing", so an event LiveKit adds later is picked
  /// up rather than silently ignored.
  void _listen(lk.Room room) {
    _cancelEvents?.call();
    _cancelEvents = room.events.listen((event) {
      if (event is lk.RoomDisconnectedEvent) {
        return _onDisconnected(event.reason);
      }
      _refreshParticipants();
    });
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
    if (_disposed) return;
    if (reason == lk.DisconnectReason.clientInitiated) return;
    await _screenShare.stopActiveBroadcast();
    _lastDisconnect = mapDisconnectReason(reason);
    _participants = const [];
    if (!_participantsController.isClosed) {
      _participantsController.add(_participants);
    }
    _setState(VoiceSessionState.failed);
    await _screenShare.dispose();
  }

  /// Drops this session's room, and everything holding it open, in the order
  /// a call has to end in. Every path that ends a call runs this: [leave], a
  /// [join] replacing a room that is still up, and [dispose].
  ///
  /// `_room` is cleared before anything else, and synchronously: a join
  /// racing this teardown reads it to tell whether it is still the current
  /// attempt, and that answer has to be final the instant a teardown starts.
  ///
  /// The room event listener's own cancellation is awaited before the room
  /// disconnects below: a straggling `RoomDisconnectedEvent` on an
  /// uncancelled listener would still reach `_onDisconnected` mid-teardown,
  /// which `_onDisconnected`'s own doc says a `leave()` must never do.
  Future<void> _teardown() async {
    // Synchronously, and before anything else; see this method's own doc.
    final room = _room;
    _room = null;
    final cancelEvents = _cancelEvents;
    _cancelEvents = null;
    if (cancelEvents != null) await _step(cancelEvents);
    // Not every call-ending path resets it; this one covers all of them.
    _cameraSwitching.resetFacing();
    // Awaited before the room disconnects below: the SFU has no bearing on iOS.
    await _step(_screenShare.stopActiveBroadcast);
    await _step(_screenShare.dispose);
    if (room != null) {
      await _step(room.disconnect);
      await _step(room.dispose);
    }
  }

  Future<bool> _trySetMicrophone(bool enabled) async {
    final room = _room;
    if (room == null) return false;
    try {
      await room.localParticipant?.setMicrophoneEnabled(enabled);
      _refreshParticipants();
      return true;
    } catch (e) {
      _lastError = e;
      _refreshParticipants();
      return false;
    }
  }

  /// Publishes (or stops) a camera track. Failure is swallowed exactly as
  /// [_trySetMicrophone]'s is: a camera pre-toggle a device cannot honour
  /// (permission denied, no hardware) must not fail the join, since a call
  /// with no camera track is still a call.
  Future<bool> _trySetCamera(bool enabled) async {
    final room = _room;
    if (room == null) return false;
    final result = await _cameraSwitching.setEnabled(
      room.localParticipant,
      enabled,
      options: cameraCaptureOptionsFor(
        room.roomOptions.defaultCameraCaptureOptions,
        _cameraQuality,
      ),
    );
    if (result.error != null) _lastError = result.error;
    // Off means the next enable republishes fresh, front-facing: reset now.
    if (!enabled && result.ok) _cameraSwitching.resetFacing();
    _refreshParticipants();
    return result.ok;
  }

  /// Delegates to [LocalAudioState.applyTo]; see that class for why this
  /// runs on every room event rather than only when a control moves.
  Future<void> _applyLocalAudioState(lk.Room room) async {
    final failure = await _audio.applyTo(room);
    if (failure != null) _lastError = failure;
  }

  /// Moved here from the main class body for its 500-line hard ceiling:
  /// private plumbing, so an extension costs it nothing an
  /// `implements VoiceSession` fake would notice.
  void _refreshParticipants() {
    final room = _room;
    if (room == null || _disposed) return;

    // Reapplied on every refresh, not only on toggle, so deafening reaches a participant or track that appears afterward too.
    unawaited(_applyLocalAudioState(room));
    // Ahead of the unchanged-roster early return below: a subscription can change with no visible roster change at all.
    _applyVideoInterest();
    unawaited(
      applyReceiveVideoQuality(
        remoteVideoQualityRefs(room),
        _receiveQuality,
        _loweredVideoSids,
      ),
    );

    final next = snapshotParticipants(
      room,
      speakingSensitivity: _speakingSensitivity,
      localVoice: _gate.running ? _gate.voice : null,
    );
    // Only emit on a real change: the events stream is chatty, and rebuilding the roster every time is how that janks.
    if (listEquals(next, _participants)) return;
    _participants = List.unmodifiable(next);
    if (!_participantsController.isClosed) {
      _participantsController.add(_participants);
    }
  }

  void _setState(VoiceSessionState next) {
    if (_state == next || _disposed) return;
    _state = next;
    if (next == VoiceSessionState.connected) {
      unawaited(_applyInputGate());
      _gate.start(_refreshParticipants);
    } else {
      _gate.stop();
    }
    if (!_stateController.isClosed) _stateController.add(next);
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
/// [VoiceSession.leave] throwing rather than settling, and whatever the
/// caller resets on a hang-up unreached - which reads on screen as a hang-up
/// that did nothing.
///
/// Deliberately does not record the failure as [VoiceSession.lastError]: that
/// field is what a join, camera or share failure turns into visible copy, and
/// a teardown has no caller left that could act on one.
Future<void> _step(Future<void> Function() run) async {
  try {
    await run();
  } catch (_) {
    // See this function's own doc comment for why nothing is kept.
  }
}
