// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sending this device's own canvas pointer, and turning everyone else's
/// into what `CanvasSurface` paints.
///
/// Split out of `canvas_pane.dart` to keep that file under the review
/// budget, the same reason `canvas_ops_controller.dart` and
/// `canvas_commit_queue.dart` already are.
library;

import 'dart:async';
import 'dart:ui';

import 'package:clock/clock.dart';
import 'package:slimm_design_system/design_system.dart' show stableIndexFor;
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// How often this device's own pointer position is relayed at most. Well
/// under what a person perceives as choppy, and far enough under the
/// server's per-connection budget (`Class::CanvasCursor`) that an ordinarily
/// moving mouse never gets throttled there instead of here.
const Duration cursorSendInterval = Duration(milliseconds: 80);

/// How long a remote cursor survives with no refresh before it is dropped.
/// Comfortably longer than [cursorSendInterval] so an ordinary gap between
/// two sends never flickers a cursor away; short enough that a closed tab or
/// somebody who moved off-canvas disappears within a few seconds rather than
/// lingering at a stale position. There is no server "stopped" frame this
/// could wait for instead; see `Event::CanvasCursorMoved`'s own doc.
const Duration cursorStaleAfter = Duration(seconds: 8);

/// How often stale cursors are swept.
const Duration cursorPruneInterval = Duration(seconds: 2);

/// The two halves of live canvas cursors: throttling this device's own
/// reports, and turning an incoming frame into what [cursors] holds.
class CanvasCursorRelay {
  CanvasCursorRelay({
    required this.cursors,
    required this.paletteSize,
    required this.send,
    required this.resolveLabel,
    required this.isBlocked,
    required this.selfId,
  }) {
    _pruneTimer = Timer.periodic(
      cursorPruneInterval,
      (_) => cursors.pruneOlderThan(cursorStaleAfter, now: clock.now()),
    );
  }

  final CanvasCursors cursors;

  /// The size of the caller's closed cursor-colour set
  /// (`AppCanvasColors.cursors.length`), so a colour index can be derived
  /// here without this package knowing what a colour is.
  final int paletteSize;

  /// Sends this device's own position onward, already throttled by the time
  /// this is called.
  final void Function(double x, double y) send;

  final String Function(String userId) resolveLabel;
  final bool Function(String userId) isBlocked;

  /// The signed-in user's own id, read fresh on every call rather than
  /// captured once, since a relay outlives a single session in principle.
  final String? Function() selfId;

  Timer? _pruneTimer;
  DateTime? _lastSent;

  /// Call on every local pointer move, drawing or not; throttles internally
  /// to [cursorSendInterval] so the caller does not have to.
  void reportLocalPointer(Offset world, {DateTime? now}) {
    final at = now ?? clock.now();
    final last = _lastSent;
    if (last != null && at.difference(last) < cursorSendInterval) return;
    _lastSent = at;
    send(world.dx, world.dy);
  }

  /// Call for every live `CanvasCursorMoved` naming this channel. Silently
  /// drops this device's own echo and a blocked author's position, the same
  /// treatment `TypingController` already gives a blocked typist.
  void applyRemote(String userId, double x, double y) {
    if (userId == selfId() || isBlocked(userId)) return;
    cursors.upsert(
      id: userId,
      x: x,
      y: y,
      label: resolveLabel(userId),
      colorIndex: canvasParticipantColorIndex(userId, paletteSize),
      now: clock.now(),
      // Seeds the glide's start from the in-flight position; harmless when a painter is given a zero (reduce-motion) glide, since it then draws the target regardless.
      glide: cursorGlideDuration,
    );
  }

  void dispose() {
    _pruneTimer?.cancel();
    cursors.clear();
  }
}

/// A stable index into a palette of [paletteSize] colours, through the same
/// `stableIndexFor` hash the avatar tint and role dot use. The cursor palette
/// is its own set of colours, so only the slot number lines up with those, not
/// the colour. Shared with `canvas_stroke_preview_relay.dart` so a
/// participant's ink and their cursor read as the same person.
int canvasParticipantColorIndex(String userId, int paletteSize) =>
    stableIndexFor(userId, paletteSize);
