// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which remote video the call keeps subscribed: the union of everything a
/// surface has mounted, narrowed to one feed while floating, and nothing when
/// nobody can see the window, except a popped-out feed, which has its own window.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'voice_controller.dart';

/// Resolves every source of video interest into the one set the call receives.
///
/// The set is never null: a call nothing is showing wants no video, which is
/// what lets the culler release the subscriptions and decoders. Audio is never
/// part of it.
class VideoInterestRelay {
  VideoInterestRelay(this._apply);

  final void Function(Set<String>?) _apply;
  final Map<Object, Set<String>> _canvas = {};
  Set<String>? _held;
  Set<String> _poppedOut = const {};
  bool _seen = true;
  final Map<String, int> _mounted = {};
  Set<String>? _sent;
  bool _mountPending = false;

  /// A canvas pane's own narrowing (its viewport or one expanded tile); null on unmount.
  /// Kept per [owner] so a pane leaving cannot clear another pane's interest in the same channel.
  void declare(Set<String>? tileKeys, {Object owner = _soleOwner}) {
    if (tileKeys == null) {
      _canvas.remove(owner);
    } else {
      _canvas[owner] = tileKeys;
    }
    _reconcile();
  }

  static const Object _soleOwner = Object();

  /// Pins interest to exactly [tileKeys] (the floating feed); null releases it.
  void hold(Set<String>? tileKeys) {
    if (setEquals(_held, tileKeys)) return;
    _held = tileKeys;
    _reconcile();
  }

  /// The feeds shown in their own OS window, which stay wanted whatever the main window is doing.
  void setPoppedOut(Set<String> tileKeys) {
    if (setEquals(_poppedOut, tileKeys)) return;
    _poppedOut = tileKeys;
    _reconcile();
  }

  /// Whether a person can see the window; false empties the interest.
  void setSeen(bool seen) {
    if (_seen == seen) return;
    _seen = seen;
    _reconcile();
  }

  /// Registers a mounted video view for [tileKey]; call the result on unmount.
  VoidCallback mount(String tileKey) {
    _mounted.update(tileKey, (n) => n + 1, ifAbsent: () => 1);
    _reconcileSoon();
    var released = false;
    return () {
      if (released) return;
      released = true;
      final left = (_mounted[tileKey] ?? 1) - 1;
      left <= 0 ? _mounted.remove(tileKey) : _mounted[tileKey] = left;
      _reconcileSoon();
    };
  }

  /// Sends the current answer again, e.g. when a call connects.
  void refresh() {
    _sent = null;
    _reconcile();
  }

  Set<String> get resolved {
    if (!_seen) return _poppedOut;
    return _held ??
        {for (final keys in _canvas.values) ...keys, ..._mounted.keys};
  }

  // Mounts happen mid-build, where the call's state must not change.
  void _reconcileSoon() {
    if (_mountPending) return;
    _mountPending = true;
    scheduleMicrotask(() {
      _mountPending = false;
      _reconcile();
    });
  }

  void _reconcile() {
    final next = resolved;
    if (setEquals(_sent, next)) return;
    _sent = next;
    _apply(next);
  }
}

final videoInterestRelayProvider = Provider<VideoInterestRelay>((ref) {
  // The canvas releases from its own dispose, which can run after the container is gone.
  var disposed = false;
  ref.onDispose(() => disposed = true);
  return VideoInterestRelay((keys) {
    if (disposed) return;
    ref.read(voiceControllerProvider.notifier).setVideoInterest(keys);
  });
});
