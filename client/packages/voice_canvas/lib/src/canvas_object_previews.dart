// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Other participants' objects mid-drag: eased between the boxes they report,
/// so a move reads as motion rather than as a teleport on drop.
library;

import 'dart:ui';

import 'canvas_document.dart';

/// How long the ease toward a newly reported box lasts: a little over the
/// 80ms the sender throttles at, so one frame's glide meets the next.
const Duration objectPreviewGlideDuration = Duration(milliseconds: 100);

/// How long an object stays where a preview left it after the sender's
/// `ended` frame, waiting for the committed move to arrive and settle it.
/// Past this the object returns to where it started: the move never landed.
const Duration objectPreviewSettleGrace = Duration(seconds: 3);

/// A preview with no frame for this long is abandoned (the sender dropped).
const Duration objectPreviewStaleAfter = Duration(seconds: 6);

typedef ObjectBox = ({double x, double y, double w, double h});

class _Preview {
  _Preview({required this.original, required this.at, required this.target})
      : from = original,
        seen = at;

  final ObjectBox original;
  ObjectBox from;
  ObjectBox target;
  DateTime at;
  DateTime seen;
  DateTime? endedAt;

  ObjectBox current(DateTime now, Duration glide) {
    if (glide <= Duration.zero) return target;
    final t = (now.difference(at).inMicroseconds / glide.inMicroseconds).clamp(
      0.0,
      1.0,
    );
    return (
      x: lerpDouble(from.x, target.x, t)!,
      y: lerpDouble(from.y, target.y, t)!,
      w: lerpDouble(from.w, target.w, t)!,
      h: lerpDouble(from.h, target.h, t)!,
    );
  }
}

/// Drives [CanvasDocument.moveObject] from remote preview frames. Owns no
/// timer: the caller calls [tick] each frame while [isActive].
class RemoteObjectPreviews {
  RemoteObjectPreviews(this.document);

  final CanvasDocument document;
  final Map<String, _Preview> _previews = <String, _Preview>{};

  /// Zero (reduce-motion) jumps straight to each reported box.
  Duration glide = objectPreviewGlideDuration;

  bool get isActive => _previews.isNotEmpty;

  /// Records the box [objectId] is now reported at, starting its ease from
  /// wherever it is drawn right now.
  void apply(String objectId, ObjectBox box, {required DateTime now}) {
    final existing = _previews[objectId];
    if (existing == null) {
      final original = document.objectBounds(objectId);
      if (original == null) return;
      _previews[objectId] = _Preview(original: original, at: now, target: box);
      return;
    }
    existing
      ..from = existing.current(now, glide)
      ..target = box
      ..at = now
      ..seen = now
      ..endedAt = null;
  }

  /// The sender let go: keep the object at its last box until the committed
  /// move settles it, or put it back after [objectPreviewSettleGrace].
  void end(String objectId, {required DateTime now}) =>
      _previews[objectId]?.endedAt = now;

  /// The committed move arrived; the preview has nothing left to say.
  void settle(String objectId) => _previews.remove(objectId);

  /// Advances every preview to [now]; returns whether more ticks are needed.
  bool tick(DateTime now) {
    final done = <String>[];
    for (final entry in _previews.entries) {
      final preview = entry.value;
      final endedAt = preview.endedAt;
      final abandoned =
          now.difference(preview.seen) > objectPreviewStaleAfter ||
              (endedAt != null &&
                  now.difference(endedAt) > objectPreviewSettleGrace);
      if (abandoned) {
        _move(entry.key, preview.original);
        done.add(entry.key);
      } else {
        _move(entry.key, preview.current(now, glide));
      }
    }
    done.forEach(_previews.remove);
    if (_previews.isNotEmpty || done.isNotEmpty) document.refresh();
    return _previews.isNotEmpty;
  }

  void _move(String id, ObjectBox box) =>
      document.moveObject(id, box.x, box.y, box.w, box.h);

  void clear() => _previews.clear();
}
