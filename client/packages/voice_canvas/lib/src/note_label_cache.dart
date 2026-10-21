// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A per-note cache of laid-out body text.
///
/// `StrokePainter` repaints on every camera move, and `_paintNote` laid its
/// text out afresh for every visible note on each one (CP9). A note's layout
/// depends only on its text and its projected size - the font scales with zoom
/// and the wrap width with the box - so during a pan (zoom fixed, boxes fixed)
/// the layout is identical frame to frame and worth keeping; a zoom, a resize
/// or an edit changes the key and rebuilds it. A miss only ever re-lays-out, so
/// unlike a stale widget cache it can never draw the wrong thing.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

/// What a note's laid-out text depends on: its text, its world width and
/// height (which set the wrap width and line count), and the revision of
/// whatever styles its spans (a member list arriving relabels a mention). Zoom
/// is not part of it: the layout is in world units and a zoom only scales it.
/// Records give this structural equality for free.
typedef NoteLayoutKey = (
  String text,
  double w,
  double h,
  int spansRevision,
);

/// Test-only: how many times each note's text was laid out, so a test can tell
/// a cache hit from a re-shape - the rendered frame looks identical either way.
@visibleForTesting
final Map<String, int> debugNoteLabelLayoutCounts = <String, int>{};

@visibleForTesting
void debugResetNoteLabelLayoutCounts() => debugNoteLabelLayoutCounts.clear();

class _CachedNote {
  _CachedNote(this.key, this.painter);
  final NoteLayoutKey key;
  final TextPainter painter;
}

/// Holds one laid-out [TextPainter] per note id, rebuilt via [build] only when
/// the note's [NoteLayoutKey] changes.
class NoteLabelCache {
  final Map<String, _CachedNote> _entries = <String, _CachedNote>{};

  int get size => _entries.length;

  /// The laid-out text for note [id], reused while [key] is unchanged and
  /// rebuilt with [build] (which must lay the returned painter out) otherwise.
  TextPainter painterFor(
    String id,
    NoteLayoutKey key,
    TextPainter Function() build,
  ) {
    final existing = _entries[id];
    if (existing != null && existing.key == key) return existing.painter;
    existing?.painter.dispose();
    final painter = build();
    _entries[id] = _CachedNote(key, painter);
    assert(() {
      debugNoteLabelLayoutCounts[id] =
          (debugNoteLabelLayoutCounts[id] ?? 0) + 1;
      return true;
    }());
    return painter;
  }

  /// Drops and disposes cached text for notes no longer present.
  void retain(Set<String> liveIds) {
    _entries.removeWhere((id, entry) {
      final dead = !liveIds.contains(id);
      if (dead) entry.painter.dispose();
      return dead;
    });
  }

  /// Disposes every cached painter; call when the owning painter tears down.
  void dispose() {
    for (final entry in _entries.values) {
      entry.painter.dispose();
    }
    _entries.clear();
  }
}
