// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending this device's own drag or resize box, and easing everyone else's
/// objects toward the boxes they report.
///
/// The object counterpart of `canvas_cursor_relay.dart`: same throttle, same
/// ephemeral channel, with the committed move op always settling the result.
library;

import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/scheduler.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_cursor_relay.dart' show cursorSendInterval;

class CanvasObjectPreviewRelay {
  CanvasObjectPreviewRelay({
    required this.previews,
    required this.send,
    required this.isBlocked,
    required this.selfId,
    required this.isDraggingLocally,
    this.glide = _fullGlide,
  });

  final RemoteObjectPreviews previews;
  final void Function(String objectId, ObjectBox box, bool ended) send;
  final bool Function(String userId) isBlocked;
  final String? Function() selfId;

  /// True while this device is itself moving [objectId]; remote frames for it
  /// are ignored so two drags cannot fight over one box.
  final bool Function(String objectId) isDraggingLocally;

  /// The ease to use right now; zero under reduce-motion. A callback because
  /// the setting lives in the widget tree, not here.
  final Duration Function() glide;

  static Duration _fullGlide() => objectPreviewGlideDuration;

  Ticker? _ticker;
  Timer? _deadline;
  DateTime? _lastSent;
  String? _activeObjectId;

  /// Call on every local drag or resize step with the box now showing.
  void reportLocal(String objectId, ObjectBox box, {DateTime? now}) {
    final at = now ?? clock.now();
    _activeObjectId = objectId;
    final last = _lastSent;
    // A clock stepped back makes the gap negative, which must not mute the relay.
    final recent =
        last != null &&
        !at.isBefore(last) &&
        at.difference(last) < cursorSendInterval;
    if (recent) return;
    _lastSent = at;
    send(objectId, box, false);
  }

  /// Call once the local gesture ends: tells watchers to stop easing.
  void endLocal(ObjectBox? finalBox) {
    final id = _activeObjectId;
    if (id == null) return;
    _activeObjectId = null;
    _lastSent = null;
    if (finalBox != null) send(id, finalBox, true);
  }

  void applyRemote(String userId, String objectId, ObjectBox box, bool ended) {
    if (userId == selfId() || isBlocked(userId)) return;
    if (isDraggingLocally(objectId)) return;
    final now = clock.now();
    previews.glide = glide();
    if (ended) {
      previews.apply(objectId, box, now: now);
      previews.end(objectId, now: now);
    } else {
      previews.apply(objectId, box, now: now);
    }
    _startTicking();
  }

  /// The committed move arrived: it is the exact final box.
  void settle(String objectId) => previews.settle(objectId, now: clock.now());

  /// A frame callback rather than a periodic timer: it fires in step with
  /// paint, and none arrive while the app is hidden.
  void _startTicking() {
    final ticker = _ticker ??= Ticker(_onFrame);
    if (!ticker.isActive) ticker.start();
    _watchDeadline();
  }

  void _onFrame(Duration _) {
    if (!previews.tick(clock.now())) _ticker?.stop();
  }

  /// One-shot wake for a frozen preview's give-up time, since no frames run
  /// then; re-armed from its own firing while previews remain.
  void _watchDeadline() {
    if (_deadline != null) return;
    final next = previews.nextDeadline;
    if (next == null) return;
    final wait = next.difference(clock.now()) + const Duration(milliseconds: 1);
    _deadline = Timer(wait.isNegative ? Duration.zero : wait, () {
      _deadline = null;
      previews.expire(clock.now());
      _watchDeadline();
    });
  }

  void dispose() {
    _ticker?.dispose();
    _ticker = null;
    _deadline?.cancel();
    _deadline = null;
    previews.clear();
  }
}
