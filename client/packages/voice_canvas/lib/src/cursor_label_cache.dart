// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A per-cursor cache of laid-out name-chip labels.
///
/// A gliding cursor repaints every frame, but its label text, colour and font
/// do not change frame to frame - only its position does. Laying the text out
/// (`TextPainter.layout`) on every paint for every visible cursor was pure
/// waste (CP5); this keeps the laid-out painter and rebuilds it only when the
/// label or its colour actually changes, disposing the one it replaces.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'cursor_label_contrast.dart';

/// Test-only: how many times each cursor's label was laid out, so a test can
/// tell a cache hit from a re-shape - a rendered frame looks identical either
/// way. Same shape as the client's `debugMemberRowBuildCounts`.
@visibleForTesting
final Map<String, int> debugCursorLabelLayoutCounts = <String, int>{};

@visibleForTesting
void debugResetCursorLabelLayoutCounts() =>
    debugCursorLabelLayoutCounts.clear();

class _CachedLabel {
  _CachedLabel(this.label, this.color, this.painter);
  final String label;
  final Color color;
  final TextPainter painter;
}

/// Holds one laid-out [TextPainter] per cursor id, keyed so it survives across
/// paints and is rebuilt only when the label or its colour changes.
class CursorLabelCache {
  CursorLabelCache({this.fontFamily});

  /// The app's own type family, constant for the life of a cache; a change to
  /// it arrives as a fresh painter and so a fresh cache.
  final String? fontFamily;

  final Map<String, _CachedLabel> _entries = <String, _CachedLabel>{};

  int get size => _entries.length;

  /// The laid-out label for [id], reused unless [label] or [color] changed.
  TextPainter painterFor(String id, String label, Color color) {
    final existing = _entries[id];
    if (existing != null &&
        existing.label == label &&
        existing.color == color) {
      return existing.painter;
    }
    existing?.painter.dispose();
    final painter = TextPainter(
      text: TextSpan(
        text: label,
        style: TextStyle(
          fontFamily: fontFamily,
          fontSize: 11,
          color: cursorLabelColorFor(color),
          height: 1,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: 160);
    _entries[id] = _CachedLabel(label, color, painter);
    assert(() {
      debugCursorLabelLayoutCounts[id] =
          (debugCursorLabelLayoutCounts[id] ?? 0) + 1;
      return true;
    }());
    return painter;
  }

  /// Drops and disposes cached labels for cursors no longer present.
  void retain(Set<String> liveIds) {
    _entries.removeWhere((id, entry) {
      final dead = !liveIds.contains(id);
      if (dead) entry.painter.dispose();
      return dead;
    });
  }

  /// Disposes every cached label; call when the owning painter is torn down.
  void dispose() {
    for (final entry in _entries.values) {
      entry.painter.dispose();
    }
    _entries.clear();
  }
}
