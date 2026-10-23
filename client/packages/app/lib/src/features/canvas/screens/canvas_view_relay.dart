// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sharing which part of the board this device shows, so others can follow it
/// or be brought to it, and following someone else's.
library;

import 'dart:async';
import 'dart:ui';

import 'package:flutter/foundation.dart';

/// How often this device's view is relayed at most while it moves.
const Duration viewSendInterval = Duration(milliseconds: 100);

/// How often a zoomed view is repeated so a late follower can find it.
const Duration viewRepeatInterval = Duration(seconds: 5);

class CanvasViewRelay {
  CanvasViewRelay({
    required this.board,
    required this.send,
    required this.showView,
    required this.isBlocked,
    required this.selfId,
    this.canSend,
  });

  /// The shared area, which is every member's view until they move.
  final Rect board;

  /// Sends this device's view onward; a summon asks everyone to jump to it.
  final void Function(Rect view, {required bool summon}) send;

  /// Shows [view] on this device, fitted to its own aspect.
  final void Function(Rect view) showView;

  final bool Function(String userId) isBlocked;
  final String? Function() selfId;
  final bool Function()? canSend;

  /// Whom this device follows, or null.
  final ValueNotifier<String?> following = ValueNotifier<String?>(null);

  final Map<String, Rect> _views = {};
  Rect? _pending;
  Rect? _lastSent;
  Timer? _throttle;
  Timer? _repeat;

  /// The last view heard from [userId]; the whole board if none was.
  Rect viewOf(String userId) => _views[userId] ?? board;

  /// Call whenever this device's visible part of the board may have changed.
  void reportLocal(Rect view) {
    if (view == _lastSent && _pending == null) return;
    _pending = view;
    if (_throttle != null) return;
    if (_flush()) _armThrottle();
  }

  // Re-armed after each send, so a view that keeps moving goes out once per interval and not twice.
  void _armThrottle() {
    _throttle = Timer(viewSendInterval, () {
      _throttle = null;
      if (_flush()) _armThrottle();
    });
  }

  /// Sends the pending view if anyone can receive it; otherwise keeps it for the next report or repeat.
  bool _flush() {
    final view = _pending;
    if (view == null) return false;
    if (!_audience()) {
      _repeat ??= Timer.periodic(viewRepeatInterval, (_) => _tick());
      return false;
    }
    _pending = null;
    _lastSent = view;
    send(view, summon: false);
    _repeat?.cancel();
    _repeat = view == board
        ? null
        : Timer.periodic(viewRepeatInterval, (_) => _tick());
    return true;
  }

  void _tick() {
    if (!_audience()) return;
    if (_pending != null) {
      _flush();
      return;
    }
    final latest = _lastSent;
    if (latest != null) send(latest, summon: false);
  }

  bool _audience() => canSend?.call() ?? true;

  /// Brings everyone else to [view].
  void summonEveryone(Rect view) => send(view, summon: true);

  /// Call for every live view frame naming this channel.
  void applyRemote(String userId, Rect view, {required bool summon}) {
    if (userId == selfId() || isBlocked(userId)) return;
    _views[userId] = view;
    if (summon || following.value == userId) showView(view);
  }

  void follow(String userId) {
    following.value = userId;
    showView(viewOf(userId));
  }

  void stopFollowing() => following.value = null;

  /// A person who left can no longer be followed, and a later return must not pull the camera.
  void forget(String userId) {
    _views.remove(userId);
    if (following.value == userId) stopFollowing();
  }

  void dispose() {
    _throttle?.cancel();
    _repeat?.cancel();
    following.dispose();
  }
}
