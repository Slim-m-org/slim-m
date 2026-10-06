// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one sentence `canvas_commit_queue.dart`, `canvas_quick_placement.dart`
/// and `canvas_image_paste.dart` each show for a draw refused with
/// `ApiException.forbidden`.
///
/// The server refuses a place/move/reorder for exactly two reasons: the
/// caller cannot view or use this channel's canvas at all, or the caller is
/// timed out (`http/canvas_write.rs`'s and `http/canvas_ops_write.rs`'s own
/// direct `timed_out_until` check, which freezes the pen without touching
/// `USE_CANVAS` - a timed-out member keeps seeing the canvas, just cannot
/// add to it). Nothing in the 403 body says which, so this reads the
/// caller's own already-fetched `Me.timedOutUntil` instead of adding a new
/// wire field for a distinction the client can already tell apart.
library;

import '../../format.dart';

/// [timedOutUntil] is the caller's own `Me.timedOutUntil` as read at the
/// moment the refusal is being explained, Unix milliseconds or null. Read
/// fresh rather than cached at pane-mount, since a timeout can start or
/// lapse while the pane stays open.
String canvasDrawForbiddenMessage(int? timedOutUntil) {
  if (timedOutUntil == null) return _drawRefusedMessage;
  final remaining = DateTime.fromMillisecondsSinceEpoch(
    timedOutUntil,
  ).difference(DateTime.now());
  if (remaining.isNegative) {
    // Lapsed between the refusal landing and this being read: nothing left to name.
    return _drawRefusedMessage;
  }
  return '$_timedOutPrefix${formatRemaining(remaining)}.';
}

const _drawRefusedMessage = "You don't have permission to draw here right now.";
const _timedOutPrefix = "You're timed out and can't draw for another ";

/// Shown when the canvas fetch is refused outright.
const canvasUnavailableMessage = 'The canvas is not available in this channel.';

/// Shown for any other failed canvas fetch.
const canvasLoadFailedMessage = 'The canvas could not be loaded.';

/// Whether [error] says placing would fail the same way again: a refusal, a
/// timeout freeze, or a canvas that never loaded. Any other banner (a failed
/// reorder or delete, an unreadable image) leaves drawing available.
bool canvasErrorBlocksDrawing(String? error) =>
    error != null &&
    (error == _drawRefusedMessage ||
        error == canvasUnavailableMessage ||
        error == canvasLoadFailedMessage ||
        error.startsWith(_timedOutPrefix));
