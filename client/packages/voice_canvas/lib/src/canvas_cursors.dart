// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Remote pointer positions on the canvas: who, where, and how stale.
///
/// A sibling of [CanvasDocument] rather than a part of it: a cursor is
/// presence, not content, and ages out on a caller-driven timer rather than
/// living in the same removed-id, undo-aware model committed ink does.
library;

import 'dart:ui' show Offset;

import 'package:flutter/foundation.dart';

/// How long a remote cursor glides to a newly-reported position: the sender
/// relays at most one frame per 80ms (`cursorSendInterval`, app side), so a
/// glide of the same length keeps an ordinarily moving pointer continuously
/// in motion instead of stepping at 12.5fps. Callers pass it through their
/// own reduce-motion gate before handing it to a painter.
const Duration cursorGlideDuration = Duration(milliseconds: 80);

/// One other participant's last-known pointer position, in world
/// coordinates, plus where it was gliding from when that position arrived.
@immutable
class CanvasCursor {
  const CanvasCursor({
    required this.id,
    required this.x,
    required this.y,
    required this.label,
    required this.colorIndex,
    required this.fromX,
    required this.fromY,
    required this.movedAt,
  });

  /// The user id this cursor belongs to.
  final String id;
  final double x;
  final double y;

  /// What a painter draws beside the pointer glyph.
  final String label;

  /// An index into the caller's own closed cursor-colour set. This package
  /// carries no palette of its own, the same convention every painter here
  /// follows; a caller derives it from [id] (e.g. a hash into the set) and
  /// keeps it stable for the life of a session.
  final int colorIndex;

  /// Where the glide toward ([x], [y]) started: the interpolated position at
  /// the moment the newest frame arrived, so a retarget mid-glide continues
  /// from where the cursor visibly was rather than jumping.
  final double fromX;
  final double fromY;

  /// When ([x], [y]) became the target, i.e. when the glide began.
  final DateTime movedAt;

  /// The position a painter should draw at [now], gliding from
  /// ([fromX], [fromY]) to ([x], [y]) over [glide]. A zero or negative
  /// [glide] answers the target directly, which is also the reduce-motion
  /// path: the caller passes the already-reduced duration in.
  Offset positionAt(DateTime now, Duration glide) {
    if (glide <= Duration.zero) return Offset(x, y);
    final elapsed = now.difference(movedAt).inMicroseconds;
    if (elapsed >= glide.inMicroseconds) return Offset(x, y);
    final t = elapsed <= 0 ? 0.0 : elapsed / glide.inMicroseconds;
    return Offset(fromX + (x - fromX) * t, fromY + (y - fromY) * t);
  }

  /// Whether [positionAt] would still answer something short of the target.
  bool glidingAt(DateTime now, Duration glide) =>
      glide > Duration.zero &&
      now.difference(movedAt) < glide &&
      (x != fromX || y != fromY);
}

/// Remote pointer positions, keyed by user id.
///
/// There is no server "stopped" frame to remove one by, unlike typing: a
/// cursor is relayed as-is with no matching end signal (see
/// `Event::CanvasCursorMoved`'s own doc, server-side), so staleness is this
/// class's own job via [pruneOlderThan] rather than something a live event
/// can ever tell it to do.
class CanvasCursors extends ChangeNotifier {
  final Map<String, CanvasCursor> _cursors = <String, CanvasCursor>{};
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};

  /// Every remote cursor currently shown.
  Iterable<CanvasCursor> get all => _cursors.values;

  Set<String> _speaking = const <String>{};

  /// Whether [id] is talking on the call right now; a painter glows their label.
  bool isSpeaking(String id) => _speaking.contains(id);

  /// Replaces who is talking; notifies only when the set changed.
  void setSpeaking(Set<String> ids) {
    if (setEquals(ids, _speaking)) return;
    _speaking = Set<String>.unmodifiable(ids);
    notifyListeners();
  }

  /// Records or refreshes one participant's position.
  ///
  /// [glide] is how long a painter will take to reach the new target; it is
  /// only used to seed the glide's own starting point from the previous
  /// target's in-flight position. A cursor seen for the first time appears
  /// at its target rather than gliding in from anywhere.
  void upsert({
    required String id,
    required double x,
    required double y,
    required String label,
    required int colorIndex,
    DateTime? now,
    Duration glide = Duration.zero,
  }) {
    final at = now ?? DateTime.now();
    final previous = _cursors[id];
    final from = previous?.positionAt(at, glide) ?? Offset(x, y);
    _cursors[id] = CanvasCursor(
      id: id,
      x: x,
      y: y,
      label: label,
      colorIndex: colorIndex,
      fromX: from.dx,
      fromY: from.dy,
      movedAt: at,
    );
    _lastSeen[id] = at;
    notifyListeners();
  }

  /// Whether any cursor is still mid-glide at [now], for a repaint driver
  /// deciding whether another frame is worth scheduling.
  bool glidingAt(DateTime now, Duration glide) =>
      _cursors.values.any((cursor) => cursor.glidingAt(now, glide));

  /// Drops every cursor not refreshed within [ttl] of [now].
  ///
  /// Meant to be called from a caller-owned periodic timer; nothing in this
  /// class schedules its own, since a `Timer.periodic` inside a
  /// `ChangeNotifier` with no `dispose` caller in a widget test is exactly
  /// the uncancellable-timer trap this project has already hit once (see
  /// `voice_roster.dart`'s own history).
  void pruneOlderThan(Duration ttl, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(ttl);
    final stale = _lastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList(growable: false);
    if (stale.isEmpty) return;
    for (final id in stale) {
      _cursors.remove(id);
      _lastSeen.remove(id);
    }
    notifyListeners();
  }

  /// Drops one cursor immediately, e.g. once its author is blocked.
  void remove(String id) {
    if (_cursors.remove(id) == null) return;
    _lastSeen.remove(id);
    notifyListeners();
  }

  /// Drops every cursor, e.g. when the pane holding this document unmounts.
  void clear() {
    if (_cursors.isEmpty) return;
    _cursors.clear();
    _lastSeen.clear();
    notifyListeners();
  }
}
