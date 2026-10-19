// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera or screen-share tile in the canvas's world space that can be
/// dragged, resized, locked so drawing reaches through it, sent back, or
/// hidden - the AR-glasses framing the owner asked for. An avatar-only tile
/// gets drag and hide only, since resize, lock and depth exist for video.
///
/// Its controls show on hover, focus or a first touch rather than always
/// (backlog reports 3 and 0.35.1), and a locked tile can always reveal its
/// own unlock button. Unless it is unlocked under the pan tool, the tile
/// passes pointers through so a pen stroke can start over it (report 2).
/// Why presence tiles are not canvas objects, and how sending one back keeps
/// its controls in place, is in docs/decisions/0010-canvas-media-tiles.md.
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

  /// A tile this small is all button once they appear, so its hover row stays away and the context menu hides it instead.
  bool get _roomForControls =>
      presenceScreenRect(_paintRect, widget.camera).shortestSide >=
      canvasPresenceTileControlsMinSide;

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

  /// Hides [child] from pointers and sight until the tile is revealed. It stays
  /// in the semantics tree so a screen reader keeps the controls, and focus
  /// within it reveals them so a keyboard user never operates an unseen one.
  Widget _revealable(BuildContext context, Widget child) {
    final shown = _controlsVisible && _roomForControls;
    return IgnorePointer(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: AppMotion.reduced(context, AppMotion.fast),
        alwaysIncludeSemantics: true,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          onFocusChange: (hasFocus) =>
              setState(() => _focusedWithin = hasFocus),
          child: child,
        ),
      ),
    );
  }

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
