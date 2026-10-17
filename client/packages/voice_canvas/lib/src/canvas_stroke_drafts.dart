// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Other participants' in-flight strokes: who, what points so far, and how
/// stale.
///
/// A sibling of `canvas_cursors.dart`'s `CanvasCursors` rather than a part of
/// it, the same reasoning: a draft is presence-shaped content, ages out on a
/// caller-driven timer, and never touches the removed-id, undo-aware model
/// committed ink lives in.
library;

import 'package:flutter/foundation.dart';

/// One other participant's in-flight stroke, accumulated from every delta
/// frame received so far.
@immutable
class CanvasStrokeDraft {
  const CanvasStrokeDraft({
    required this.objectId,
    required this.authorId,
    required this.points,
    required this.colorIndex,
  });

  /// A client-minted id keying this preview session. Never a real,
  /// committed object id: the object(s) a finished stroke commits are
  /// decided later, and one stroke can split into several.
  final String objectId;

  final String authorId;

  /// Flat `[x0,y0,x1,y1,...]`, in world units, every point relayed so far
  /// for this draft.
  final List<double> points;

  /// See `CanvasCursors`' own `CanvasCursor.colorIndex`.
  final int colorIndex;
}

/// Most points one draft keeps, past which the oldest are dropped.
///
/// A hostile or misbehaving peer can keep one draft "open" indefinitely by
/// refreshing it just under [strokePreviewStaleAfter] forever, never sending
/// `ended` - the server charges this by bytes, not by a draft's total
/// lifetime, so nothing server-side stops that. Without a ceiling here, every
/// *other* viewer's [_drafts] entry for that id would grow without bound, and
/// [RemoteDraftPainter] rebuilds a [Path] over the whole accumulated list on
/// every repaint, so an unbounded draft is both unbounded memory and
/// quadratic paint cost over the attack's duration. 4000 points is several
/// times more than a fast continuous gesture produces in the several seconds
/// a real stroke actually takes, so this is never visible in ordinary use.
const int maxDraftPreviewPoints = 4000;

/// Remote in-flight strokes, keyed by [CanvasStrokeDraft.objectId].
///
/// There is an explicit "ended" signal, unlike a cursor - a stroke carries
/// content, so a receiver should not have to wait out a staleness timer to
/// stop showing a ghost the drawer already finished or abandoned - but
/// [pruneOlderThan] still exists for the case that signal never arrives: a
/// mid-stroke disconnect.
class RemoteStrokeDrafts extends ChangeNotifier {
  final Map<String, CanvasStrokeDraft> _drafts = <String, CanvasStrokeDraft>{};
  final Map<String, DateTime> _lastSeen = <String, DateTime>{};

  /// Every in-flight stroke currently shown.
  Iterable<CanvasStrokeDraft> get all => _drafts.values;

  /// Appends [points] to whatever this [objectId] already holds, or starts a
  /// new draft if this is the first frame seen for it.
  void appendOrCreate({
    required String objectId,
    required String authorId,
    required List<double> points,
    required int colorIndex,
    DateTime? now,
  }) {
    final existing = _drafts[objectId];
    final merged = existing == null
        ? List<double>.from(points)
        : (List<double>.from(existing.points)..addAll(points));
    const maxDoubles = maxDraftPreviewPoints * 2;
    final capped = merged.length > maxDoubles
        ? merged.sublist(merged.length - maxDoubles)
        : merged;
    _drafts[objectId] = CanvasStrokeDraft(
      objectId: objectId,
      authorId: authorId,
      points: capped,
      colorIndex: colorIndex,
    );
    _lastSeen[objectId] = now ?? DateTime.now();
    notifyListeners();
  }

  /// Drops one draft immediately: the drawer signalled the gesture ended, or
  /// its author was blocked.
  void end(String objectId) {
    if (_drafts.remove(objectId) == null) return;
    _lastSeen.remove(objectId);
    notifyListeners();
  }

  /// Drops every draft not refreshed within [ttl] of [now]. Meant to be
  /// called from a caller-owned periodic timer, the same shape
  /// `CanvasCursors.pruneOlderThan` already documents the reasoning for.
  void pruneOlderThan(Duration ttl, {DateTime? now}) {
    final cutoff = (now ?? DateTime.now()).subtract(ttl);
    final stale = _lastSeen.entries
        .where((entry) => entry.value.isBefore(cutoff))
        .map((entry) => entry.key)
        .toList(growable: false);
    if (stale.isEmpty) return;
    for (final id in stale) {
      _drafts.remove(id);
      _lastSeen.remove(id);
    }
    notifyListeners();
  }

  /// Drops every draft, e.g. when the pane holding this document unmounts.
  void clear() {
    if (_drafts.isEmpty) return;
    _drafts.clear();
    _lastSeen.clear();
    notifyListeners();
  }
}
