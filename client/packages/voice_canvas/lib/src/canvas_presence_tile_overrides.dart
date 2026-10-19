// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a call participant's camera or screen-share tile actually sits on
/// a channel's canvas, once somebody has dragged, resized, locked or
/// restacked it away from [CanvasPresenceLayout]'s default arrangement.
///
/// Position, size, lock and depth are shared and persistent - decision
/// 0010's reversal of its own first call, made on the owner's own
/// instruction: "when i join the canvas, move something to a specific X, Y
/// position... it should still be at X and Y, not reset". The server
/// (`canvas_media_slots` table) is the source of truth; this class is the
/// client's own mirror of it, kept current by a fetch on open and by live
/// `canvas.media_slot.changed` frames (`CanvasMediaSlotSync`, in the app
/// package, owns both). [hidden] is the one field that stays exactly as it
/// was: local, personal, and reset on rejoin via [prune].
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'canvas_board.dart';
import 'canvas_stroke.dart';

/// One tile's departure from its default position, size and interactivity.
/// [rect] is null until the server (or a not-yet-committed local drag) has
/// ever answered for this key; a null field always means "use whatever
/// [CanvasPresenceLayout] would otherwise say," never "hide."
@immutable
class CanvasPresenceTileState {
  const CanvasPresenceTileState({
    this.rect,
    this.locked = false,
    this.hidden = false,
    this.sentToBack = false,
  });

  final Rect? rect;

  /// Shared, not personal: a locked tile stops intercepting the pointer for
  /// *every* viewer - a drawing tool, or a pan, reaches straight through it
  /// - protecting an arrangement everyone relies on the same way Figma's
  /// own layer lock does, rather than describing only this viewer's own
  /// pointer.
  final bool locked;

  /// Personal. Never sent to the server, never touched by [applyServer] -
  /// see this file's own library doc.
  final bool hidden;

  /// Shared, the same reason [locked] is: whether this tile's own pixels
  /// paint behind the drawing surface rather than above it - see
  /// `canvas_presence_backdrop.dart`'s own doc for why that has to be a
  /// second widget rather than a reorder of this one.
  final bool sentToBack;

  CanvasPresenceTileState copyWith({
    Rect? rect,
    bool? locked,
    bool? hidden,
    bool? sentToBack,
  }) =>
      CanvasPresenceTileState(
        rect: rect ?? this.rect,
        locked: locked ?? this.locked,
        hidden: hidden ?? this.hidden,
        sentToBack: sentToBack ?? this.sentToBack,
      );
}

const _defaultTileState = CanvasPresenceTileState();

/// Keyed by a tile key of the shape `'camera:<userId>'` or
/// `'screen:<userId>'` - an opaque string, the same convention
/// [CanvasPresenceVisibility] and `CanvasPresenceLayout.arrange` already
/// accept unmodified, so nothing here has to know what kind of tile a key
/// names.
class CanvasPresenceTileOverrides extends ChangeNotifier {
  final Map<String, CanvasPresenceTileState> _states = {};

  /// Which tile last had its rect touched *this session*, most recent last -
  /// a drag or resize is "bring to front" the same way picking up a real
  /// sheet of paper puts it on top of the pile, so an untouched
  /// participant's default-positioned tile can never sit over one this
  /// viewer just moved. Deliberately local and per-mount, unlike everything
  /// else this class stores: it orders same-screen overlap for one viewer's
  /// own eye, never sent anywhere, and [sentToBack] (front-versus-drawing-
  /// surface depth) is the shared concept the owner's own "front or back"
  /// request actually asked for.
  int _nextZ = 0;
  final Map<String, int> _z = {};

  /// True for exactly as long as [setRect] is actively pinning a dragged
  /// tile to `worldLimit` - [CanvasDocument.worldEdgeHit]'s own sibling for
  /// a tile drag rather than a camera pan, feeding the same edge-glow
  /// overlay.
  final ValueNotifier<bool> worldEdgeHit = ValueNotifier<bool>(false);

  /// The shared board every tile is held inside; null leaves tiles unbounded.
  Rect? board;

  Rect _onBoard(Rect rect) {
    final frame = board;
    return frame == null ? rect : fitBoxIntoBoard(rect, frame);
  }

  CanvasPresenceTileState stateFor(String key) =>
      _states[key] ?? _defaultTileState;

  /// This key's own place in the touch order, or null if it has never been
  /// dragged or resized this session - the render order [CanvasPresenceLayer]
  /// sorts by.
  int? zFor(String key) => _z[key];

  /// Whether this key sits behind the drawing surface (the shared front/back
  /// depth). Paint order uses it as the primary key so every sent-to-back
  /// tile - and its controls - sits beneath every front tile, before the
  /// per-viewer touch order breaks ties within each group.
  bool sentToBackFor(String key) => stateFor(key).sentToBack;

  /// Replaces [rect]/[locked]/[sentToBack] with the server's current answer
  /// for [key] - a fetch on opening the canvas, or a live
  /// `canvas.media_slot.changed` frame - leaving [hidden] untouched, since
  /// that field is never shared. The server already enforces its own world
  /// bound on write, so this does not re-clamp [rect].
  void applyServer(
    String key, {
    required Rect rect,
    required bool locked,
    required bool sentToBack,
  }) {
    _states[key] = stateFor(key)
        .copyWith(rect: _onBoard(rect), locked: locked, sentToBack: sentToBack);
    notifyListeners();
  }

  /// Optimistic, local-only update for the live-while-dragging feel; the
  /// caller (`CanvasPresenceLayer`) is responsible for also committing the
  /// result to the server once the gesture settles, or this drifts from
  /// what every other viewer sees. [rect]'s position is clamped to
  /// [worldLimit], the same bound [CanvasDocument]'s own camera is held to -
  /// a real canvas object is bounded at the server, and an in-flight local
  /// drag has not reached that check yet, so an unclamped drag could
  /// otherwise carry it a million units away with no way back before the
  /// commit lands. Size is left alone: the widget that calls this already
  /// clamps a resize to `canvasPresenceTileMinSize`/`Max`.
  void setRect(String key, Rect rect) {
    final clampedLeft = rect.left.clamp(-worldLimit, worldLimit);
    final clampedTop = rect.top.clamp(-worldLimit, worldLimit);
    final clamped = _onBoard(
      Rect.fromLTWH(clampedLeft, clampedTop, rect.width, rect.height),
    );
    worldEdgeHit.value = clamped.topLeft != rect.topLeft;
    _states[key] = stateFor(key).copyWith(rect: clamped);
    _z[key] = _nextZ++;
    notifyListeners();
  }

  /// Optimistic, local-only; see [setRect]'s own doc for why the caller
  /// still has to commit this onward.
  void setLocked(String key, bool locked) {
    _states[key] = stateFor(key).copyWith(locked: locked);
    notifyListeners();
  }

  /// Optimistic, local-only; see [setRect]'s own doc for why the caller
  /// still has to commit this onward.
  void setSentToBack(String key, bool sentToBack) {
    _states[key] = stateFor(key).copyWith(sentToBack: sentToBack);
    notifyListeners();
  }

  /// Local and personal - never sent to the server. Unlike [setRect] and
  /// its siblings, this one needs no further commit.
  void setHidden(String key, bool hidden) {
    _states[key] = stateFor(key).copyWith(hidden: hidden);
    notifyListeners();
  }

  /// Every key currently marked hidden, for a recovery affordance to list -
  /// a hide must stay reversible, or it is a delete wearing a softer name.
  Iterable<String> get hiddenKeys =>
      _states.entries.where((e) => e.value.hidden).map((e) => e.key);

  /// Drops [hidden] for every key not in [present] - call once per roster
  /// change. That field alone still resets on rejoin, the "reset on
  /// rejoin" shape STRATEGY calls for on presence objects generally; a
  /// participant who left and later rejoins starts back with their tile
  /// unhidden. [rect], [locked] and [sentToBack] are shared and persistent
  /// now and are never dropped here: the server, not roster membership, is
  /// their source of truth, and a departed participant's tile is still
  /// worth remembering for whenever they - or whoever moved it - is back.
  /// The local touch order in [_z] is dropped too, since it is a purely
  /// this-session paint-stacking concern with nothing to persist.
  void prune(Set<String> present) {
    var changed = false;
    for (final entry in _states.entries.toList()) {
      if (present.contains(entry.key) || !entry.value.hidden) continue;
      _states[entry.key] = entry.value.copyWith(hidden: false);
      changed = true;
    }
    final beforeZ = _z.length;
    _z.removeWhere((key, _) => !present.contains(key));
    if (changed || _z.length != beforeZ) notifyListeners();
  }

  @override
  void dispose() {
    worldEdgeHit.dispose();
    super.dispose();
  }
}
