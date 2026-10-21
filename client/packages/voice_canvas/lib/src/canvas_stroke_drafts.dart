// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Other participants' in-flight strokes: who, what points so far, and how
/// stale.
///
/// A sibling of `canvas_cursors.dart`'s `CanvasCursors` rather than a part of
/// it, the same reasoning: a draft is presence-shaped content, ages out on a
/// caller-driven timer, and never touches the removed-id, undo-aware model
/// committed ink lives in.
library;

import 'dart:math' as math;
import 'dart:ui';

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
    this.colorKey,
    this.width,
    this.ended = false,
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

  /// The drawer's pen colour key and world width, when they sent them; the
  /// ghost paints with these so it does not change look when it lands.
  final String? colorKey;
  final double? width;

  /// The box the points span, for matching the ghost to the ink that lands.
  Rect get bounds {
    var minX = double.infinity;
    var minY = double.infinity;
    var maxX = double.negativeInfinity;
    var maxY = double.negativeInfinity;
    for (var i = 0; i + 1 < points.length; i += 2) {
      minX = math.min(minX, points[i]);
      maxX = math.max(maxX, points[i]);
      minY = math.min(minY, points[i + 1]);
      maxY = math.max(maxY, points[i + 1]);
    }
    return minX > maxX ? Rect.zero : Rect.fromLTRB(minX, minY, maxX, maxY);
  }

  /// The drawer let go: kept showing until their committed stroke arrives so
  /// the ink never blinks out between the two.
  final bool ended;
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

/// How long a finished draft waits for its committed stroke before it is
/// dropped as a gesture that never committed.
const Duration finishedDraftGrace = Duration(seconds: 5);

/// Finished draft ids remembered so a frame arriving late cannot revive one.
const int finishedDraftMemory = 64;

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
  final Map<String, Rect> _landed = <String, Rect>{};
  final List<String> _retired = <String>[];

  /// Every in-flight stroke currently shown.
  Iterable<CanvasStrokeDraft> get all => _drafts.values;

  /// Appends [points] to whatever this [objectId] already holds, or starts a
  /// new draft if this is the first frame seen for it.
  void appendOrCreate({
    required String objectId,
    required String authorId,
    required List<double> points,
    required int colorIndex,
    String? colorKey,
    double? width,
    DateTime? now,
  }) {
    if (_retired.contains(objectId)) return;
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
      colorKey: colorKey ?? existing?.colorKey,
      width: width ?? existing?.width,
      ended: existing?.ended ?? false,
    );
    _lastSeen[objectId] = now ?? DateTime.now();
    notifyListeners();
  }

  /// Marks a draft finished but keeps it painted until [settleAuthor] or
  /// [pruneOlderThan] removes it, bridging the gap before the committed
  /// stroke arrives.
  void finish(String objectId, {DateTime? now}) {
    final draft = _drafts[objectId];
    if (draft == null || draft.ended) return;
    _drafts[objectId] = CanvasStrokeDraft(
      objectId: draft.objectId,
      authorId: draft.authorId,
      points: draft.points,
      colorIndex: draft.colorIndex,
      colorKey: draft.colorKey,
      width: draft.width,
      ended: true,
    );
    _lastSeen[objectId] = now ?? DateTime.now();
    notifyListeners();
  }

  /// A committed stroke by [authorId] arrived: drops their finished drafts.
  ///
  /// With [landed], the box of the ink that arrived, a draft goes only once
  /// the ink landed so far covers it, so a stroke split into several
  /// segments keeps its ghost until the last one lands rather than shrinking
  /// to the first.
  void settleAuthor(String? authorId, {Rect? landed}) {
    if (authorId == null) return;
    final drafts =
        _drafts.values.where((d) => d.ended && d.authorId == authorId);
    if (drafts.isEmpty) return;
    final covered = landed == null
        ? null
        : (_landed[authorId] =
            _landed[authorId]?.expandToInclude(landed) ?? landed);
    final done = [
      for (final draft in drafts)
        if (covered == null || _covers(covered, draft)) draft.objectId,
    ];
    if (done.isNotEmpty) _landed.remove(authorId);
    done.forEach(end);
  }

  static bool _covers(Rect landed, CanvasStrokeDraft draft) {
    final reach = landed.inflate((draft.width ?? 3) + 2);
    final box = draft.bounds;
    return reach.left <= box.left &&
        reach.top <= box.top &&
        reach.right >= box.right &&
        reach.bottom >= box.bottom;
  }

  /// Drops one draft immediately: the drawer signalled the gesture ended, or
  /// its author was blocked.
  void end(String objectId) {
    if (_drafts.remove(objectId) == null) return;
    _lastSeen.remove(objectId);
    _retired.add(objectId);
    if (_retired.length > finishedDraftMemory) _retired.removeAt(0);
    notifyListeners();
  }

  /// Drops every draft not refreshed within [ttl] of [now]. Meant to be
  /// called from a caller-owned periodic timer, the same shape
  /// `CanvasCursors.pruneOlderThan` already documents the reasoning for.
  void pruneOlderThan(Duration ttl, {DateTime? now}) {
    final at = now ?? DateTime.now();
    final cutoff = at.subtract(ttl);
    final endedCutoff = at.subtract(finishedDraftGrace);
    final stale = _lastSeen.entries
        .where(
          (entry) =>
              entry.value.isBefore(cutoff) ||
              (_drafts[entry.key]?.ended == true &&
                  entry.value.isBefore(endedCutoff)),
        )
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
    _landed.clear();
    _retired.clear();
    notifyListeners();
  }
}
