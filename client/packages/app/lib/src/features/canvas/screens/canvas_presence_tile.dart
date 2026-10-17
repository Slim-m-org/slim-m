// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The AR-glasses interaction the owner asked for by name: a camera or
/// screen-share tile you can drag anywhere in the canvas's own world space,
/// resize with a grip, lock so a drawing tool reaches through it, or hide.
///
/// An avatar-only tile - a camera key whose participant's camera is off -
/// gets only the drag and the hide; report 4's own line, "the pfp should not
/// be broken or resizeable," is [fixedRenderSize] (no grip, a fixed paint
/// box regardless of any stale resize) plus null [onToggleLocked] and
/// [onToggleSentToBack] (no lock or depth row at all): resize exists for a
/// video tile's own aspect ratio, and lock/depth exist so a drawing tool
/// reaches through or over a video track, none of which a bare avatar has.
///
/// Deliberately not built on the drag-and-resize state machine
/// `canvas_ops_controller_select.dart` already drives for a real
/// [CanvasObjectKind] - a presence tile is not one of those (see
/// `canvas_presence_layer.dart`'s own doc for why), so it owns a short,
/// self-contained gesture handler instead, the same shape the self bubble's
/// old screen-anchored drag already used before this file replaced it.
///
/// Being locked, or [tool] not being [CanvasTool.pan], wraps only the
/// content in [IgnorePointer]: the resize grip disappears too (nothing to
/// resize while it is not reachable) but the lock control itself never
/// does, or a locked tile would be a dead end with no way back.
///
/// The resize grip and the lock/depth/hide row are hidden - both visually
/// and to hit-testing - until this tile is hovered (desktop) or pressed
/// once (touch, where there is no hover): permanently painting three
/// buttons over every participant's video was report 3 in the backlog
/// channel. The reveal has to live on the outer [Listener] that already
/// wraps this whole tile, not on the controls themselves, because that is
/// the one piece of this widget [locked]'s own [IgnorePointer] never
/// reaches - see this file's own doc above for why the outer `Listener`
/// already has to see every pointer within the tile regardless of lock
/// state. So a locked tile still reveals its own unlock button on a hover
/// or a first press, the same "never a dead end" guarantee [locked] itself
/// already makes.
///
/// The owner reported the same complaint a second time on 0.35.1, after the
/// hover/press reveal above had already shipped, which is what closed the
/// remaining gap: hover and a touch press are not the only ways a person
/// reaches a control. [_focusedWithin] reveals the same row for a keyboard
/// user tabbing onto it, on the owner's own instruction that hover is the
/// desktop-pointer answer and focus has to be the desktop-keyboard one -
/// [IgnorePointer] blocks a pointer tap, never focus traversal, so a hidden
/// button was already Tab-then-Enter reachable, just invisible while it
/// happened, which is worse than either fully hidden or fully shown. A
/// touch press keeps the tap-to-reveal shape it already had (report 3's own
/// fix): a tile is the thing being touched to begin with, so a tap on it
/// costs nothing a drag or a resize was not already going to spend, and the
/// three-second [canvasPresenceTileTouchRevealDuration] window is enough
/// for the follow-up tap on a lock, depth or hide button that a real touch
/// sequence needs. The participant name badge in `canvas_presence_bubble
/// .dart` stays always-on rather than joining this same gate: it identifies
/// whose tile this is for as long as the tile is up, the same job a name
/// label does in every other call surface this app has, where the row of
/// three action buttons and the resize grip are each a thing somebody does
/// once and moves on from.
///
/// [CanvasPresenceManipulableTile.sentToBack] never touches this widget's
/// own layout, gesture handling or paint position at all - see
/// `canvas_presence_layer.dart`'s own doc for why. Only [child] differs
/// (an invisible placeholder when sent to back, the real content
/// otherwise), so the drag area, resize grip and corner controls stay
/// exactly where a person last saw them, whichever side of the drawing
/// surface the tile's own pixels are currently painting on.
///
/// The outer shell (the [MouseRegion] and the [Listener] both) is opaque,
/// replicating a middle-mouse grab-pan and a mouse wheel itself against
/// [document], only while this tile is unlocked with [CanvasTool.pan]
/// active - the one state where a pointer here means "manipulate this
/// tile". Any other [tool], or [locked] regardless of [tool], turns both
/// `HitTestBehavior.translucent` and ignores the content: report 2 in the
/// backlog channel, "unable to start drawing on attachments", is exactly a
/// pen stroke that would not start over a camera bubble, and report 4 is a
/// locked, sent-to-back tile still swallowing a click meant for whatever
/// `CanvasSurface` paints above it. Translucent still delivers every raw
/// pointer here, so [_revealForTouch] always runs and a locked tile's own
/// unlock button never becomes a dead end - but the pan/wheel replication
/// itself stops, since `CanvasSurface` now genuinely receives the same
/// gesture directly and a second copy here would double it.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_presence_geometry.dart' show presenceScreenRect;
import 'canvas_presence_tile_context_menu.dart';
import 'canvas_presence_tile_controls.dart';
import 'canvas_presence_tile_metrics.dart';

export 'canvas_presence_tile_metrics.dart';

class CanvasPresenceManipulableTile extends StatefulWidget {
  const CanvasPresenceManipulableTile({
    super.key,
    required this.worldRect,
    required this.camera,
    required this.locked,
    required this.tool,
    required this.sentToBack,
    required this.onRectChanged,
    required this.onRectCommitted,
    this.onToggleLocked,
    this.onToggleSentToBack,
    required this.onHide,
    required this.semanticLabel,
    required this.document,
    required this.child,
    this.onExpand,
    this.fixedRenderSize,
    this.participantItemsBuilder,
  });

  final Rect worldRect;
  final Camera camera;
  final bool locked;

  /// The canvas's own active tool - see this file's own library doc for why
  /// anything but [CanvasTool.pan] makes this tile transparent to a
  /// pointer the same way [locked] already does.
  final CanvasTool tool;

  /// Whether this tile's own content currently paints behind
  /// [CanvasSurface] rather than above it - purely informational here, for
  /// the corner control's own icon and label; see this file's own doc for
  /// why depth never changes anything else about this widget.
  final bool sentToBack;

  /// Only read for a middle-mouse grab-pan starting on this tile - see the
  /// library doc for why that one gesture is handled here directly rather
  /// than left to reach `CanvasSurface` on its own.
  final CanvasDocument document;

  /// Fired on every drag/resize update, in world space - the caller owns
  /// persisting it (`CanvasPresenceTileOverrides.setRect`), this widget owns
  /// only the arithmetic and the live-while-dragging feel.
  final ValueChanged<Rect> onRectChanged;

  /// Fired once, when a drag or resize settles - the caller's cue to send
  /// the now-final rect onward to the server (`CanvasPresenceLayer.onCommit`),
  /// since every intermediate [onRectChanged] frame stays purely local.
  final VoidCallback onRectCommitted;

  /// Null renders no lock button at all, the same shape [onExpand] already
  /// uses - see [fixedRenderSize]'s own doc for why an avatar-only tile
  /// passes null here.
  final VoidCallback? onToggleLocked;

  /// Null renders no depth button at all - see [onToggleLocked]'s own doc.
  final VoidCallback? onToggleSentToBack;
  final VoidCallback onHide;

  /// Forwarded straight to [TileControls.onExpand] - see its own doc for why
  /// null renders no button rather than a disabled one.
  final VoidCallback? onExpand;
  final String semanticLabel;
  final Widget child;

  /// This tile's own paint and hit-test box, in world units, when it is not
  /// [worldRect]'s size at all - the avatar-only case, whose fixed footprint
  /// is `canvasAvatarMarkerSize`. [worldRect] itself is left completely
  /// alone: [_drag] still shifts it by the pointer's own delta and hands the
  /// *unshrunk* result to [onRectChanged], so a size this widget merely
  /// paints smaller than never overwrites the size a video tile sharing this
  /// same server-side slot would need back the moment its camera comes on.
  /// Null keeps every existing camera and screen-share tile pixel-identical
  /// to before this field existed - painted at [worldRect] itself, resizable
  /// via [TileResizeGrip], lockable, and depth-toggleable.
  final Size? fixedRenderSize;

  /// Forwarded to `CanvasPresenceTileContextMenu.participantItemsBuilder` - see that field's own doc. Null for this device's own tile.
  final List<Widget> Function(BuildContext tileContext, VoidCallback close)?
  participantItemsBuilder;
  @override
  State<CanvasPresenceManipulableTile> createState() =>
      _CanvasPresenceManipulableTileState();
}

class _CanvasPresenceManipulableTileState
    extends State<CanvasPresenceManipulableTile> {
  /// The seam a right-click on this tile opens its own context menu
  /// through - see `canvas_presence_tile_context_menu.dart`'s own library
  /// doc for why a controller, not a `GlobalKey`, carries that open call.
  final _menuController = CanvasPresenceTileMenuController();

  /// Non-null only while a drag or resize is in flight. Tracking it locally,
  /// rather than trusting [CanvasPresenceManipulableTile.worldRect] to have
  /// already round-tripped through the caller's own state and back by the
  /// next pointer event, is what keeps a fast drag from stuttering on a
  /// rebuild that has not landed yet.
  Rect? _liveRect;

  Rect get _rect => _liveRect ?? widget.worldRect;

  /// See this file's own library doc: true whenever a pointer landing on
  /// this tile means something to whatever is stacked behind it instead of
  /// to this tile itself.
  bool get _passThrough => widget.locked || widget.tool != CanvasTool.pan;

  /// [_rect], with its size swapped for [CanvasPresenceManipulableTile
  /// .fixedRenderSize] when one is given - the box this widget actually
  /// paints and hit-tests at, kept separate from [_rect] itself so [_drag]
  /// can go on reporting [_rect]'s own, unshrunk size to [_settle]'s caller.
  Rect get _paintRect {
    final fixed = widget.fixedRenderSize;
    return fixed == null
        ? _rect
        : Rect.fromLTWH(_rect.left, _rect.top, fixed.width, fixed.height);
  }

  void _drag(DragUpdateDetails details) {
    final next = _rect.shift(details.delta / widget.camera.zoom);
    setState(() => _liveRect = next);
    widget.onRectChanged(next);
  }

  void _resize(DragUpdateDetails details) {
    final delta = details.delta / widget.camera.zoom;
    final current = _rect;
    final width = (current.width + delta.dx).clamp(
      canvasPresenceTileMinSize.width,
      canvasPresenceTileMaxSize.width,
    );
    final height = (current.height + delta.dy).clamp(
      canvasPresenceTileMinSize.height,
      canvasPresenceTileMaxSize.height,
    );
    final next = Rect.fromLTWH(current.left, current.top, width, height);
    setState(() => _liveRect = next);
    widget.onRectChanged(next);
  }

  void _settle(DragEndDetails details) {
    setState(() => _liveRect = null);
    widget.onRectCommitted();
  }

  /// This tile's own pan pointer, so an unrelated second pointer's own
  /// button cannot steer or end a grab it did not start - the same guard
  /// `_beginPan`'s own doc gives `CanvasSurface`.
  int? _panPointer;
  Offset? _panFrom;

  /// Every pointer this tile has told [CanvasExternalPointers] about but not
  /// yet told it left - see that class's own doc for why `CanvasSurface`
  /// needs to hear about a pointer it never itself received a down event
  /// for. A set, not a count, because [dispose] has to balance exactly the
  /// pointers this instance actually added, never a guess.
  final Set<int> _countedPointers = {};

  bool _isPanButton(int buttons) => buttons & kMiddleMouseButton != 0;

  /// True while a mouse sits over this tile - [MouseRegion.onEnter]/
  /// [MouseRegion.onExit] track it directly and need no timer, since a
  /// mouse always reports leaving.
  bool _hovering = false;

  /// True while a touch's own reveal is still active - [_revealForTouch]
  /// (re)starts [_hideTimer] on every press, so a held or repeated touch
  /// keeps the controls up rather than letting them vanish mid-interaction.
  bool _revealedForTouch = false;
  Timer? _hideTimer;

  /// True while keyboard focus sits on the grip or on any control in the
  /// row - a plain `Focus.hasFocus` on the wrapping node in [_revealable],
  /// which Flutter already defines as true for the node itself or any of
  /// its descendants, so one flag serves every button without tracking each
  /// one separately.
  bool _focusedWithin = false;

  bool get _controlsVisible => _hovering || _revealedForTouch || _focusedWithin;

  void _onHoverEnter(PointerEnterEvent _) => setState(() => _hovering = true);
  void _onHoverExit(PointerExitEvent _) => setState(() => _hovering = false);

  /// Called on every pointer down within this tile, mouse or touch alike -
  /// harmless for a mouse, which already reveals through [_hovering] and
  /// will have exited (clearing this too) well before [_hideTimer] could
  /// ever fire.
  void _revealForTouch() {
    _hideTimer?.cancel();
    if (!_revealedForTouch) setState(() => _revealedForTouch = true);
    _hideTimer = Timer(canvasPresenceTileTouchRevealDuration, () {
      if (mounted) setState(() => _revealedForTouch = false);
    });
  }

  void _pointerDown(PointerDownEvent event) {
    // Unconditional even in pass-through: see this file's own library doc.
    _revealForTouch();
    if (_passThrough) return;
    _countedPointers.add(event.pointer);
    widget.document.externalPointers.add();
    if (_panPointer == null && _isPanButton(event.buttons)) {
      _panPointer = event.pointer;
      _panFrom = event.position;
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    if (event.pointer != _panPointer) return;
    if (!_isPanButton(event.buttons)) {
      _panPointer = null;
      _panFrom = null;
      return;
    }
    final from = _panFrom!;
    final delta = event.position - from;
    _panFrom = event.position;
    final camera = widget.document.camera;
    widget.document.setCamera(
      camera.copyWith(
        x: camera.x - delta.dx / camera.zoom,
        y: camera.y - delta.dy / camera.zoom,
      ),
    );
  }

  void _pointerUp(PointerEvent event) {
    if (_countedPointers.remove(event.pointer)) {
      widget.document.externalPointers.remove();
    }
    if (event.pointer == _panPointer) {
      _panPointer = null;
      _panFrom = null;
    }
  }

  /// A wheel notch landing inside this tile's own opaque bounds - see this
  /// file's own library doc for why `CanvasSurface` never gets a chance to
  /// answer for it otherwise, and never has to while [_passThrough] is
  /// true, when it does. [event.localPosition] is relative to this tile's
  /// own top-left, not the canvas viewport `cameraAfterWheelScroll` expects,
  /// so it is re-based onto this tile's own on-screen origin before being
  /// handed to the same pure math `CanvasSurface` reads.
  void _onPointerSignal(PointerSignalEvent event) {
    if (_passThrough) return;
    if (event is! PointerScrollEvent) return;
    final screen = presenceScreenRect(_paintRect, widget.camera);
    final focal = screen.topLeft + event.localPosition;
    final keys = HardwareKeyboard.instance;
    widget.document.setCamera(
      cameraAfterWheelScroll(
        widget.document.camera,
        focal: focal,
        dx: event.scrollDelta.dx,
        dy: event.scrollDelta.dy,
        zoomModifier: keys.isControlPressed || keys.isMetaPressed,
        horizontalModifier: keys.isShiftPressed,
      ),
    );
  }

  @override
  void dispose() {
    for (final _ in _countedPointers) {
      widget.document.externalPointers.remove();
    }
    _countedPointers.clear();
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Wraps [child] so it is invisible and unreachable by a pointer while
  /// this tile's own reveal is inactive, and both otherwise - the grip and
  /// the controls row share this, never the tile's own content, which draws
  /// and hit-tests exactly as before.
  ///
  /// `alwaysIncludeSemantics: true` is load-bearing, not tidiness:
  /// [AnimatedOpacity] excludes its child from the semantics tree at zero
  /// opacity by default, which would have made a screen reader's own swipe
  /// navigation lose these controls entirely rather than only the pointer
  /// route this fix means to gate - a strictly worse accessibility position
  /// than before this file ever hid anything. [IgnorePointer] still blocks
  /// an ordinary pointer tap while hidden; a screen reader's own activation
  /// reaches straight through it regardless, the same way it always could.
  ///
  /// The [Focus] wrapper is what stops a sighted keyboard user from tabbing
  /// onto, and operating, a control they cannot see: [IgnorePointer] gates a
  /// pointer only, never focus traversal, so without this a hidden
  /// `AppIconButton` was already reachable and already activatable by Tab
  /// then Enter, just invisible while it happened. `canRequestFocus: false`
  /// keeps this node itself out of the tab order - only its real children
  /// (the icon buttons) are stops - and Flutter's own `FocusNode.hasFocus`
  /// is already true for a node whenever a descendant holds focus, so one
  /// listener here answers for every button in [child] without wiring each
  /// one separately.
  Widget _revealable(BuildContext context, Widget child) => IgnorePointer(
    ignoring: !_controlsVisible,
    child: AnimatedOpacity(
      opacity: _controlsVisible ? 1 : 0,
      duration: AppMotion.reduced(context, AppMotion.fast),
      alwaysIncludeSemantics: true,
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onFocusChange: (hasFocus) => setState(() => _focusedWithin = hasFocus),
        child: child,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final screen = presenceScreenRect(_paintRect, widget.camera);
    return Positioned(
      left: screen.left,
      top: screen.top,
      width: screen.width,
      height: screen.height,
      child: MouseRegion(
        onEnter: _onHoverEnter,
        onExit: _onHoverExit,
        // MouseRegion defaults its own hitTestBehavior to opaque too, which absorbs a pointer before the Listener below ever gets a say - it has to carry the same pass-through choice, or that Listener's own translucent is moot.
        hitTestBehavior: _passThrough
            ? HitTestBehavior.translucent
            : HitTestBehavior.opaque,
        child: Listener(
          // Translucent in pass-through so this Listener's own handlers still fire and whatever CanvasSurface paints beneath still gets the same pointer; opaque otherwise, or a not-yet-revealed tile could never be touched to reveal at all.
          behavior: _passThrough
              ? HitTestBehavior.translucent
              : HitTestBehavior.opaque,
          onPointerDown: _pointerDown,
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          onPointerSignal: _onPointerSignal,
          child: Semantics(
            container: true,
            label: widget.semanticLabel,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CanvasPresenceTileContextMenu(
                  controller: _menuController,
                  locked: widget.locked,
                  sentToBack: widget.sentToBack,
                  onToggleLocked: widget.onToggleLocked,
                  onToggleSentToBack: widget.onToggleSentToBack,
                  onHide: widget.onHide,
                  onExpand: widget.onExpand,
                  participantItemsBuilder: widget.participantItemsBuilder,
                ),
                IgnorePointer(
                  ignoring: _passThrough,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    // Opens this tile's own menu rather than a no-op now, but still HitTestBehavior.opaque - a right-click on a tile must never leak to a canvas object underneath it, `canvas_self_presence_overlay.dart`'s old precedent for this exact absorption. onLongPressStart is its touch equivalent (law 3), matching canvas_object_context_menu.dart's own precedent.
                    onSecondaryTapUp: (details) =>
                        _menuController.open(details.globalPosition),
                    onLongPressStart: (details) =>
                        _menuController.open(details.globalPosition),
                    onPanUpdate: _drag,
                    onPanEnd: _settle,
                    child: widget.child,
                  ),
                ),
                if (!_passThrough && widget.fixedRenderSize == null)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _revealable(
                      context,
                      TileResizeGrip(onUpdate: _resize, onEnd: _settle),
                    ),
                  ),
                Positioned(
                  right: 2,
                  top: 2,
                  child: _revealable(
                    context,
                    TileControls(
                      locked: widget.locked,
                      sentToBack: widget.sentToBack,
                      onExpand: widget.onExpand,
                      onToggleLocked: widget.onToggleLocked,
                      onToggleSentToBack: widget.onToggleSentToBack,
                      onHide: widget.onHide,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
