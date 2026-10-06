// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Unsubscribing a remote video track nothing is showing, rather than only
/// letting LiveKit pause it.
///
/// LiveKit's own `adaptiveStream` already stops the *bytes*: a track with no
/// mounted renderer anywhere gets an `UpdateTrackSettings(disabled: true)`
/// and the SFU stops forwarding it. What that never releases is the
/// subscription itself - the transceiver and the decoder stay allocated for
/// as long as the call lasts, which on a device with a finite number of
/// hardware decode sessions is the cost that actually bites when a canvas
/// carries more tiles than fit on screen.
///
/// So this is deliberately the second, slower half of a two-stage cull, not
/// a replacement for the first. [videoSubscriptionDwell] is set to twice
/// LiveKit's own 1500ms `UpdateTrackSettings` debounce precisely so the
/// cheap pause always lands first, and a full unsubscribe only ever reaches
/// a track that has been unwanted long enough for the cheap answer to have
/// already been applied and still not been enough.
///
/// **Audio is never touched, at all, by anything here.** Unsubscribing
/// somebody's microphone because their tile scrolled off screen would
/// silence a live call, which is a worse bug than any amount of wasted
/// decoder. [VoiceSession]'s own walk never offers this class an audio
/// publication in the first place, and this class refuses one anyway if it
/// ever sees one; the redundancy is the point, since the two halves fail
/// independently.
///
/// Takes its room access as plain closures on a record rather than a
/// LiveKit type, exactly the shape [ScreenShareControl] already uses and for
/// the same reason: the interesting part is a state machine over time, and a
/// state machine that needs a signalling server to test is a state machine
/// nobody tests.
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

/// How long a track stays subscribed after nothing wants it any more.
///
/// Three seconds, chosen against two real numbers rather than picked. It is
/// twice `RemoteTrackPublication`'s own 1500ms track-settings debounce, so
/// LiveKit's cheap pause is always already in flight before this fires. And
/// it comfortably outlasts a pan out and back, which the caller's own
/// spatial hysteresis band (see `CanvasPresenceVisibility`) has already had
/// to be crossed twice for a track to become a candidate at all - so the
/// common "look over there, look back" gesture never reaches this timer,
/// and what does reach it is a tile somebody has genuinely left behind.
const videoSubscriptionDwell = Duration(seconds: 3);

/// One remote video publication, described with no LiveKit type in sight.
///
/// [key] is `'<kind>:<identity>'` - the same shape the canvas's own
/// `presenceTileKeys` produces, so an interest set can be passed straight
/// through with no translation. Only `camera` and `screen` are ever acted
/// on; see [cullableTrackKinds].
typedef VideoSubscriptionRef = ({
  String key,
  bool subscribed,
  Future<void> Function() subscribe,
  Future<void> Function() unsubscribe,
});

/// The kind half of a camera tile's key.
const cameraTrackKind = 'camera';

/// The kind half of a screen-share tile's key.
const screenTrackKind = 'screen';

/// The tile-key prefixes a cull may ever touch. Anything else - most
/// importantly an audio publication, however it reached here - is left
/// exactly as it was found.
const cullableTrackKinds = {cameraTrackKind, screenTrackKind};

/// The one place a `'<kind>:<identity>'` key is built.
///
/// Shared rather than duplicated because the canvas builds these keys too
/// (`presenceTileKeys`) and the two have to agree exactly: a key the canvas
/// names and this package does not would mean an interest set that matches
/// nothing, which is not a mismatch that degrades gracefully - it culls
/// every remote video in the call. One function, so the convention cannot
/// drift across the package seam the way two matching string literals in two
/// packages eventually would.
String videoSubscriptionKey({
  required String identity,
  required bool screenShare,
}) =>
    '${screenShare ? screenTrackKind : cameraTrackKind}:$identity';

/// The kind half of a `'<kind>:<identity>'` tile key.
String videoSubscriptionKind(String key) {
  final colon = key.indexOf(':');
  return colon < 0 ? key : key.substring(0, colon);
}

/// A rejected subscribe/unsubscribe - a participant leaving mid-cull is the
/// ordinary case here - is logged and dropped, never left unhandled for the
/// zone to report as a crash.
void Function(Object error) _logRejection(String key, String action) =>
    (error) => debugPrint(
        'video subscription culler: $action rejected for $key: $error');

/// Decides which remote video tracks stay subscribed, given what some
/// surface says it currently wants on screen.
///
/// Asymmetric on purpose: subscribing back is immediate, unsubscribing waits
/// out [dwell]. The cost of being slow to resubscribe is a black tile
/// somebody is looking at; the cost of being slow to unsubscribe is a little
/// memory nobody can see.
class VideoSubscriptionCuller {
  VideoSubscriptionCuller({
    required this.onDue,
    this.dwell = videoSubscriptionDwell,
  });

  /// Called once a dwell elapses, asking the owner to walk its room afresh
  /// and call [apply] again. The timer never acts on a publication itself:
  /// the reference it was scheduled with may be several room events stale by
  /// the time it fires, and acting on a stale one is how a disposed
  /// publication gets touched.
  final void Function() onDue;

  final Duration dwell;

  Set<String>? _interest;
  final Map<String, Timer> _pending = {};
  final Set<String> _due = {};
  bool _disposed = false;

  /// What some surface currently wants video for.
  ///
  /// Null means nothing has an opinion, which is not the same as wanting
  /// nothing: every track stays (or becomes) subscribed. That distinction is
  /// the whole mechanism, and it is what a surface says when it unmounts or
  /// when it is not in a position to speak for the call at all - the same
  /// null-versus-empty split `SyncController`'s own `opCursor` draws.
  void setInterest(Set<String>? keys) {
    if (_disposed) return;
    _interest = keys == null ? null : Set.unmodifiable(keys);
    // A dwell is meaningless once nothing can be unwanted, and [apply] cannot clear one for a caller whose room has already gone away.
    if (keys == null) {
      for (final key in _pending.keys.toList(growable: false)) {
        _cancel(key);
      }
    }
  }

  /// Reconciles [tracks] against the current interest, subscribing anything
  /// wanted that is not subscribed and unsubscribing anything unwanted whose
  /// dwell has already elapsed.
  void apply(Iterable<VideoSubscriptionRef> tracks) {
    if (_disposed) return;
    final seen = <String>{};
    for (final track in tracks) {
      if (!cullableTrackKinds.contains(videoSubscriptionKind(track.key))) {
        continue;
      }
      seen.add(track.key);
      final interest = _interest;
      if (interest == null || interest.contains(track.key)) {
        _cancel(track.key);
        if (!track.subscribed) {
          unawaited(track
              .subscribe()
              .catchError(_logRejection(track.key, 'subscribe')));
        }
        continue;
      }
      if (!track.subscribed) {
        _cancel(track.key);
        continue;
      }
      if (_due.remove(track.key)) {
        unawaited(
          track
              .unsubscribe()
              .catchError(_logRejection(track.key, 'unsubscribe')),
        );
        continue;
      }
      _pending[track.key] ??= Timer(dwell, () => _elapsed(track.key));
    }
    // A key the room no longer carries at all keeps no timer of its own.
    for (final key in _pending.keys.toList(growable: false)) {
      if (!seen.contains(key)) _cancel(key);
    }
    _due.removeWhere((key) => !seen.contains(key));
  }

  void _elapsed(String key) {
    _pending.remove(key);
    _due.add(key);
    onDue();
  }

  void _cancel(String key) {
    _pending.remove(key)?.cancel();
    _due.remove(key);
  }

  void dispose() {
    _disposed = true;
    for (final timer in _pending.values) {
      timer.cancel();
    }
    _pending.clear();
    _due.clear();
  }
}
