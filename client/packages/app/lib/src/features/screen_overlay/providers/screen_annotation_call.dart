// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which relayed screen marks belong to the call this client is in.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:slimm_api/api.dart' as api;

/// Whether [frame] was drawn in the call on [callChannelId], by someone in [callMembers] over the screen of someone in it.
///
/// The rule the server relays by, kept here too so a server without it cannot paint a mark from another call.
bool markInCall(
  api.CanvasScreenAnnotation frame, {
  required String? callChannelId,
  required Iterable<String> callMembers,
}) => frame.channelId == callChannelId && _seated(frame, callMembers);

bool _seated(api.CanvasScreenAnnotation frame, Iterable<String> members) =>
    members.contains(frame.userId) && members.contains(frame.targetUserId);

/// How long a mark waits for my LiveKit roster, which lags a fresh joiner, to show its sender and target.
const rosterGrace = Duration(seconds: 5);

/// Marks from my call that wait for the roster to seat their sender and target.
///
/// Released in arrival order once both are seated; dropped after [grace] or when the call changes.
class RosterHold {
  RosterHold({
    required String? Function() callChannelId,
    required Iterable<String> Function() callMembers,
    required void Function(api.CanvasScreenAnnotation frame) release,
    this.grace = rosterGrace,
  }) : _callChannelId = callChannelId,
       _callMembers = callMembers,
       _release = release;

  /// A few seconds of one stroke's updates; a flood past it loses its oldest.
  static const capacity = 256;

  final String? Function() _callChannelId;
  final Iterable<String> Function() _callMembers;
  final void Function(api.CanvasScreenAnnotation frame) _release;
  final Duration grace;
  final _held = <(api.CanvasScreenAnnotation, Timer)>[];

  /// Holds [frame] and returns true when it is from my call but the roster lacks its sender or target.
  bool holds(api.CanvasScreenAnnotation frame) {
    if (frame.channelId != _callChannelId()) return false;
    if (_seated(frame, _callMembers())) return false;
    if (_held.length >= capacity) _held.removeAt(0).$2.cancel();
    late final (api.CanvasScreenAnnotation, Timer) entry;
    entry = (frame, Timer(grace, () => _held.remove(entry)));
    _held.add(entry);
    return true;
  }

  /// Call when the roster or the call changes.
  void recheck() {
    if (_held.isEmpty) return;
    final channel = _callChannelId();
    final members = _callMembers().toSet();
    final ready = <api.CanvasScreenAnnotation>[];
    _held.removeWhere((entry) {
      final frame = entry.$1;
      final elsewhere = frame.channelId != channel;
      if (!elsewhere && !_seated(frame, members)) return false;
      entry.$2.cancel();
      if (!elsewhere) ready.add(frame);
      return true;
    });
    ready.forEach(_release);
  }

  @visibleForTesting
  int get heldCount => _held.length;

  void dispose() {
    for (final entry in _held) {
      entry.$2.cancel();
    }
    _held.clear();
  }
}
