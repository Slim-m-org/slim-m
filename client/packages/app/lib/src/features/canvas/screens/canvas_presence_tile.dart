// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera or screen-share tile's controls in world space: drag, resize, lock so drawing reaches through it, or hide.
/// They show on hover, focus or a first touch, and a locked tile can always reveal its unlock button.
/// Why tiles are not canvas objects: docs/decisions/0010-canvas-media-tiles.md; why ink paints above them: 0086.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_pointer_gate.dart';
import 'canvas_presence_geometry.dart' show presenceScreenRect;
import 'canvas_presence_tile_camera.dart';
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
    required this.onRectChanged,
    required this.onRectCommitted,
    this.onToggleLocked,
    required this.onHide,
    required this.semanticLabel,
    required this.document,
    required this.child,
    this.onExpand,
    this.participantItemsBuilder,
    this.onPointerMoved,
    this.personal = false,
  });

  final Rect worldRect;
  final Camera camera;
  final bool locked;

  /// The canvas's own active tool - see this file's own library doc for why
  /// anything but [CanvasTool.pan] makes this tile transparent to a
  /// pointer the same way [locked] already does.
  final CanvasTool tool;

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
  /// uses; the personal view passes null because lock is a shared action.
  final VoidCallback? onToggleLocked;
  final VoidCallback onHide;

  /// Forwarded straight to [TileControls.onExpand] - see its own doc for why
  /// null renders no button rather than a disabled one.
  final VoidCallback? onExpand;
  final String semanticLabel;
  final Widget child;

  /// Forwarded to `CanvasPresenceTileContextMenu.participantItemsBuilder` - see that field's own doc. Null for this device's own tile.
  final List<Widget> Function(BuildContext tileContext, VoidCallback close)?
  participantItemsBuilder;

  /// Relays this device's pointer while it is over the tile, which hides the surface's own hover.
  final PointerMoved? onPointerMoved;

  /// Whether the tile is being placed for this device alone; a change mid-drag cancels the drag.
  final bool personal;
  @override
  State<CanvasPresenceManipulableTile> createState() =>
      _CanvasPresenceManipulableTileState();
}

const _dragDevices = {
  PointerDeviceKind.touch,
  PointerDeviceKind.mouse,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

class _CanvasPresenceManipulableTileState
    extends State<CanvasPresenceManipulableTile> {
  /// The seam a right-click on this tile opens its own context menu
  /// through - see `canvas_presence_tile_context_menu.dart`'s own library
  /// doc for why a controller, not a `GlobalKey`, carries that open call.
  final _menuController = CanvasPresenceTileMenuController();

  late final _camera = TileCameraForwarder(
    document: widget.document,
    originOf: () => presenceScreenRect(_rect, widget.camera).topLeft,
  );

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

  Rect? _dragStartRect;
  Offset _dragTotal = Offset.zero;
  bool _dragPersonal = false;
  bool _dragCancelled = false;
  ({Offset at, DateTime time})? _lastClick;

  void _onBodyPanDown(DragDownDetails details) {
    if (widget.onExpand == null || _camera.pinching || _panPointer != null) {
      return;
    }
    final now = DateTime.now();
    final last = _lastClick;
    if (last != null &&
        now.difference(last.time) <= kDoubleTapTimeout &&
        (details.globalPosition - last.at).distance <= kDoubleTapSlop) {
      _lastClick = null;
      widget.onExpand?.call();
      return;
    }
    _lastClick = (at: details.globalPosition, time: now);
  }

  void _dragStart(DragStartDetails details) {
    _dragStartRect = _rect;
    _dragTotal = Offset.zero;
    _dragPersonal = widget.personal;
    _dragCancelled = false;
  }

  void _drag(DragUpdateDetails details) {
    // A summon flips the board to shared mid-drag; carrying on would write the shared rect for everyone.
    if (_dragCancelled || widget.personal != _dragPersonal) {
      _dragCancelled = true;
      return;
    }
    if (_camera.pinching || _panPointer != null) return;
    _dragTotal += details.delta;
    if (_dragTotal.distance > kTouchSlop) _lastClick = null;
    // From the start rect and the total travel, so the overshoot past a clamp is not lost.
    final next = widget.document.placeOnBoard(
      (_dragStartRect ?? _rect).shift(_dragTotal / widget.camera.zoom),
    );
    setState(() => _liveRect = next);
    widget.onRectChanged(next);
  }

  void _dragEnd(DragEndDetails details) {
    if (_dragCancelled) {
      setState(() => _liveRect = null);
      return;
    }
    _settle(details);
  }

  void _resize(DragUpdateDetails details) {
    final next = widget.document.placeOnBoard(
      canvasPresenceTileResized(
        _rect,
        details.delta / widget.camera.zoom,
        widget.document.board,
      ),
    );
    setState(() => _liveRect = next);
    widget.onRectChanged(next);
  }

  void _settle(DragEndDetails details) {
    setState(() => _liveRect = null);
    widget.onRectCommitted();
  }

  /// This tile's own pan pointer, so a second pointer cannot steer or end a grab it did not start.
  int? _panPointer;
  Offset? _panFrom;

  /// Pointers reported to [CanvasExternalPointers] and not yet released; a set so [dispose] balances exactly what was added.
  final Set<int> _countedPointers = {};

  bool _isPanButton(int buttons) =>
      buttons & kMiddleMouseButton != 0 ||
      (buttons & kPrimaryButton != 0 &&
          HardwareKeyboard.instance.isLogicalKeyPressed(
            LogicalKeyboardKey.space,
          ));

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

  // A stroke started over the controls would otherwise end on one of them.
  bool get _controlsVisible =>
      widget.tool == CanvasTool.pan &&
      (_hovering || _revealedForTouch || _focusedWithin);

  /// A tile this small is all button once they appear, so its row shows only the buttons that fit and the context menu carries the rest.
  int get _controlCapacity => canvasPresenceTileControlCapacity(
    presenceScreenRect(_rect, widget.camera).size,
    touch: AppTouchTargets.of(context),
  );

  void _onHoverEnter(PointerEnterEvent _) => setState(() => _hovering = true);
  void _onHoverExit(PointerExitEvent _) => setState(() => _hovering = false);

  /// Called on every pointer down in this tile; harmless for a mouse, which reveals through [_hovering] and exits before [_hideTimer] fires.
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
    _camera.touchDown(event);
    _countedPointers.add(event.pointer);
    widget.document.externalPointers.add();
    if (_panPointer == null && _isPanButton(event.buttons)) {
      _panPointer = event.pointer;
      _panFrom = event.position;
    }
  }

  void _pointerMove(PointerMoveEvent event) {
    _relayPointer(event.localPosition);
    if (_passThrough) return;
    _camera.touchMove(event);
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
    _camera.touchUp(event);
    if (_countedPointers.remove(event.pointer)) {
      widget.document.externalPointers.remove();
    }
    if (event.pointer == _panPointer) {
      _panPointer = null;
      _panFrom = null;
    }
  }

  void _relayPointer(Offset local) {
    final relay = widget.onPointerMoved;
    if (relay == null) return;
    final screen = presenceScreenRect(_rect, widget.camera).topLeft + local;
    final camera = widget.document.camera;
    relay(
      Offset(
        camera.x + screen.dx / camera.zoom,
        camera.y + screen.dy / camera.zoom,
      ),
    );
  }

  /// Forwarded to [TileCameraForwarder.signal] unless in pass-through mode.
  void _onPointerSignal(PointerSignalEvent event) {
    if (!_passThrough) _camera.signal(event);
  }

  @override
  void dispose() {
    for (final _ in _countedPointers) {
      widget.document.externalPointers.remove();
    }
    _countedPointers.clear();
    _hideTimer?.cancel();
    _camera.reset();
    super.dispose();
  }

  late final Widget _grip = TileResizeGrip(onUpdate: _resize, onEnd: _settle);

  Widget? _controlsWidget;
  ({bool locked, bool expand, bool lock, int fit})? _controlsShape;

  /// The control row is rebuilt only when its shape changes: it sits invisible on every tile at every camera tick otherwise.
  Widget _controls() {
    final shape = (
      locked: widget.locked,
      expand: widget.onExpand != null,
      lock: widget.onToggleLocked != null,
      fit: _controlCapacity,
    );
    if (_controlsWidget == null || _controlsShape != shape) {
      _controlsShape = shape;
      _controlsWidget = TileControls(
        locked: shape.locked,
        maxButtons: shape.fit,
        onExpand: shape.expand ? () => widget.onExpand?.call() : null,
        onToggleLocked: shape.lock ? () => widget.onToggleLocked?.call() : null,
        onHide: () => widget.onHide(),
      );
    }
    return _controlsWidget!;
  }

  /// Hides [child] from pointers and sight until the tile is revealed. It stays
  /// in the semantics tree so a screen reader keeps the controls, and focus
  /// within it reveals them so a keyboard user never operates an unseen one.
  Widget _revealable(
    BuildContext context,
    Widget child, {
    bool needsRoom = true,
  }) {
    final room = !needsRoom || _controlCapacity > 0;
    final shown = _controlsVisible && room;
    return CanvasPointerGate(
      ignoring: !shown,
      child: AnimatedOpacity(
        opacity: shown ? 1 : 0,
        duration: AppMotion.reduced(context, AppMotion.fast),
        alwaysIncludeSemantics: true,
        // A control with no room never shows, so keyboard focus must not land on it unseen.
        child: ExcludeFocus(
          excluding: !room,
          // The tile's own menu carries these actions, so a no-room control publishes no node over the tile.
          child: ExcludeSemantics(
            excluding: !room,
            child: Focus(
              canRequestFocus: false,
              skipTraversal: true,
              onFocusChange: (hasFocus) =>
                  setState(() => _focusedWithin = hasFocus),
              onKeyEvent: (_, event) => _fullscreenKey(event),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  // F opens the tile full screen from whichever of its controls has keyboard focus.
  KeyEventResult _fullscreenKey(KeyEvent event) {
    final onExpand = widget.onExpand;
    final keyboard = HardwareKeyboard.instance;
    if (onExpand == null ||
        event is! KeyDownEvent ||
        event.logicalKey != LogicalKeyboardKey.keyF ||
        keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed) {
      return KeyEventResult.ignored;
    }
    onExpand();
    return KeyEventResult.handled;
  }

  void _openMenuAtCentre() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _menuController.open(box.localToGlobal(box.size.center(Offset.zero)));
  }

  @override
  Widget build(BuildContext context) {
    final screen = presenceScreenRect(_rect, widget.camera);
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
          onPointerHover: (event) => _relayPointer(event.localPosition),
          onPointerPanZoomStart: (event) {
            if (!_passThrough) _camera.trackpadStart(event);
          },
          onPointerPanZoomUpdate: (event) {
            if (!_passThrough) _camera.trackpadUpdate(event);
          },
          onPointerMove: _pointerMove,
          onPointerUp: _pointerUp,
          onPointerCancel: _pointerUp,
          onPointerSignal: _onPointerSignal,
          child: Semantics(
            container: true,
            label: widget.semanticLabel,
            // The menu a right-click or a hold opens; the gesture below publishes nothing, since a semantic tap never sends its secondary tap.
            onLongPress: _openMenuAtCentre,
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                CanvasPresenceTileContextMenu(
                  controller: _menuController,
                  locked: widget.locked,
                  onToggleLocked: widget.onToggleLocked,
                  onHide: widget.onHide,
                  onExpand: widget.onExpand,
                  participantItemsBuilder: widget.participantItemsBuilder,
                ),
                IgnorePointer(
                  ignoring: _passThrough,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    excludeFromSemantics: true,
                    // Opens this tile's own menu rather than a no-op now, but still HitTestBehavior.opaque - a right-click on a tile must never leak to a canvas object underneath it, `canvas_self_presence_overlay.dart`'s old precedent for this exact absorption. onLongPressStart is its touch equivalent (law 3), matching canvas_object_context_menu.dart's own precedent.
                    onSecondaryTapUp: (details) =>
                        _menuController.open(details.globalPosition),
                    onLongPressStart: (details) =>
                        _menuController.open(details.globalPosition),
                    // A trackpad scroll moves the camera, not the tile.
                    supportedDevices: _dragDevices,
                    onPanDown: _onBodyPanDown,
                    onPanStart: _dragStart,
                    onPanUpdate: _drag,
                    onPanEnd: _dragEnd,
                    child: widget.child,
                  ),
                ),
                if (!_passThrough)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: _revealable(context, _grip, needsRoom: false),
                  ),
                Positioned(
                  right: canvasPresenceTileControlsInset,
                  top: canvasPresenceTileControlsInset,
                  child: _revealable(context, _controls()),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
