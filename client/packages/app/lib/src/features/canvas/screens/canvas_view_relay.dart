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

/// How long a summon waits for an answer before it lapses without a word.
const Duration summonRequestTimeout = Duration(seconds: 30);

/// Someone asking this device to jump to [view].
typedef SummonRequest = ({String userId, Rect view});

class CanvasViewRelay {
  CanvasViewRelay({
    required this.board,
    required this.send,
    required this.showView,
    required this.isBlocked,
    required this.selfId,
    this.canSend,
    this.focusedTile,
  });

  /// The shared area, which is every member's view until they move.
  final Rect board;

  /// Sends this device's view onward; a summon asks everyone to jump to it, and [tile] is the call tile this device has full screen.
  final void Function(Rect view, {required bool summon, String? tile}) send;

  /// Shows [view] on this device, fitted to its own aspect.
  final void Function(Rect view) showView;

  final bool Function(String userId) isBlocked;
  final String? Function() selfId;
  final bool Function()? canSend;

  /// The call tile this device has full screen, or null.
  final String? Function()? focusedTile;

  /// Whom this device follows, or null.
  final ValueNotifier<String?> following = ValueNotifier<String?>(null);

  /// The call tile the followed person has full screen, or null; cleared when following ends.
  final ValueNotifier<String?> followedTile = ValueNotifier<String?>(null);

  /// A summon waiting for this person's answer, or null.
  final ValueNotifier<SummonRequest?> summonRequest =
      ValueNotifier<SummonRequest?>(null);

  final Map<String, Rect> _views = {};
  final Map<String, String?> _tiles = {};
  Timer? _summonExpiry;
  bool _disposed = false;
  Rect? _pending;
  Rect? _lastSent;
  String? _lastTile;
  Timer? _throttle;
  Timer? _repeat;

  /// The last view heard from [userId]; the whole board if none was.
  Rect viewOf(String userId) => _views[userId] ?? board;

  /// Call whenever this device's visible part of the board may have changed.
  void reportLocal(Rect view) {
    if (view == _lastSent && _pending == null && _lastTile == _tile()) return;
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
    _lastTile = _tile();
    send(view, summon: false, tile: _lastTile);
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
    if (latest != null) send(latest, summon: false, tile: _lastTile);
  }

  String? _tile() => focusedTile?.call();

  bool _audience() => canSend?.call() ?? true;

  /// Brings everyone else to [view].
  void summonEveryone(Rect view) => send(view, summon: true);

  /// Call for every live view frame naming this channel.
  void applyRemote(
    String userId,
    Rect view, {
    required bool summon,
    String? tile,
  }) {
    if (userId == selfId() || isBlocked(userId)) return;
    _views[userId] = view;
    _tiles[userId] = tile;
    if (following.value == userId) {
      showView(view);
      followedTile.value = tile;
    } else if (summon) {
      _ask(userId, view);
    }
  }

  void _ask(String userId, Rect view) {
    summonRequest.value = (userId: userId, view: view);
    _summonExpiry?.cancel();
    _summonExpiry = Timer(summonRequestTimeout, declineSummon);
  }

  /// Moves to the summoner's view. [beforeMoving] runs first, so a full screen receiver can leave it.
  Future<void> acceptSummon({Future<void> Function()? beforeMoving}) async {
    final request = summonRequest.value;
    if (request == null) return;
    declineSummon();
    await beforeMoving?.call();
    if (!_disposed) showView(request.view);
  }

  /// Dismisses the request, which is also how it times out.
  void declineSummon() {
    _summonExpiry?.cancel();
    _summonExpiry = null;
    summonRequest.value = null;
  }

  void follow(String userId) {
    following.value = userId;
    showView(viewOf(userId));
    followedTile.value = _tiles[userId];
  }

  void stopFollowing() {
    following.value = null;
    followedTile.value = null;
  }

  /// A person who left can no longer be followed, and a later return must not pull the camera.
  void forget(String userId) {
    _views.remove(userId);
    _tiles.remove(userId);
    if (summonRequest.value?.userId == userId) declineSummon();
    if (following.value == userId) stopFollowing();
  }

  void dispose() {
    _disposed = true;
    _throttle?.cancel();
    _repeat?.cancel();
    _summonExpiry?.cancel();
    following.dispose();
    followedTile.dispose();
    summonRequest.dispose();
  }
}
