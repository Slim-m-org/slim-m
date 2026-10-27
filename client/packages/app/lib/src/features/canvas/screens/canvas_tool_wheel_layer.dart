// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Opens the tool wheel when a mouse's right button is held on empty canvas,
/// or from the keyboard, and carries its pick out to the pane.
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_tool_wheel.dart';

/// Shares one right-button hold between the wheel and the quick-actions menu
/// that opens on the same button's release, and lets the keyboard ask for the wheel.
class CanvasToolWheelController extends ChangeNotifier {
  bool _holdOpened = false;

  /// True from a hold opening the wheel until the next right press, so the release that ends the hold opens no second menu.
  bool get suppressSecondaryTap => _holdOpened;

  void holdOpened() => _holdOpened = true;

  void pressStarted() => _holdOpened = false;

  /// Asks the wheel to open at the middle of the canvas; the keyboard's route to it.
  void requestOpen() => notifyListeners();
}

class CanvasToolWheelLayer extends StatefulWidget {
  const CanvasToolWheelLayer({
    super.key,
    required this.document,
    required this.controller,
    required this.tool,
    required this.shapeKind,
    required this.canDraw,
    required this.isObjectAt,
    required this.onToolChanged,
    required this.onPasteImageAt,
  });

  final CanvasDocument document;
  final CanvasToolWheelController controller;
  final CanvasTool tool;
  final CanvasShapeKind shapeKind;
  final bool canDraw;

  /// Whether a right-click at this world point belongs to an object's own menu.
  final bool Function(Offset world) isObjectAt;
  final ValueChanged<CanvasTool> onToolChanged;
  final ValueChanged<Offset> onPasteImageAt;

  @override
  State<CanvasToolWheelLayer> createState() => _CanvasToolWheelLayerState();
}

class _CanvasToolWheelLayerState extends State<CanvasToolWheelLayer> {
  final _portal = OverlayPortalController();
  final _highlight = ValueNotifier<CanvasWheelItem?>(null);
  Timer? _holdTimer;
  int? _pointer;
  Offset _pressLocal = Offset.zero;
  Offset _pressGlobal = Offset.zero;
  bool _flicked = false;
  Offset _center = Offset.zero;
  Offset _world = Offset.zero;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_openAtMiddle);
  }

  @override
  void didUpdateWidget(CanvasToolWheelLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_openAtMiddle);
      widget.controller.addListener(_openAtMiddle);
    }
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    widget.controller.removeListener(_openAtMiddle);
    _highlight.dispose();
    super.dispose();
  }

  RenderBox? get _overlayBox {
    final box = Overlay.of(context).context.findRenderObject();
    return box is RenderBox ? box : null;
  }

  Offset _toWorld(Offset local) {
    final camera = widget.document.camera;
    return Offset(
      camera.x + local.dx / camera.zoom,
      camera.y + local.dy / camera.zoom,
    );
  }

  void _down(PointerDownEvent event) {
    widget.controller.pressStarted();
    if (event.kind != PointerDeviceKind.mouse ||
        event.buttons != kSecondaryMouseButton) {
      return;
    }
    _cancelHold();
    _pointer = event.pointer;
    _pressLocal = event.localPosition;
    _pressGlobal = event.position;
    _holdTimer = Timer(kLongPressTimeout, () {
      _holdTimer = null;
      _openHeld();
    });
  }

  void _move(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if (!_portal.isShowing) {
      if ((event.localPosition - _pressLocal).distance > kTouchSlop) {
        _cancelHold();
      }
      return;
    }
    final overlay = _overlayBox;
    if (overlay == null) return;
    if ((event.position - _pressGlobal).distance > kTouchSlop) _flicked = true;
    _highlight.value = _flicked
        ? _itemAt(overlay.globalToLocal(event.position))
        : null;
  }

  void _up(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _cancelHold();
    _pointer = null;
    final reached = _highlight.value;
    if (_portal.isShowing && reached != null) _pick(reached);
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
  }

  CanvasWheelItem? _itemAt(Offset overlayPoint) {
    final index = canvasWheelSector(
      center: _center,
      pointer: overlayPoint,
      count: CanvasWheelItem.values.length,
    );
    if (index == null) return null;
    final item = CanvasWheelItem.values[index];
    return item.isAvailable(canDraw: widget.canDraw) ? item : null;
  }

  void _openHeld() {
    if (widget.isObjectAt(_toWorld(_pressLocal))) return;
    widget.controller.holdOpened();
    _open(anchorGlobal: _pressGlobal, world: _toWorld(_pressLocal));
  }

  void _openAtMiddle() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return;
    _open(
      anchorGlobal: box.localToGlobal(box.size.center(Offset.zero)),
      world: widget.document.worldView.center,
    );
  }

  void _open({required Offset anchorGlobal, required Offset world}) {
    final overlay = _overlayBox;
    if (overlay == null || _portal.isShowing) return;
    _flicked = false;
    _highlight.value = null;
    _world = world;
    setState(() {
      _center = canvasWheelCenter(
        overlay.globalToLocal(anchorGlobal),
        overlay.size,
        MediaQuery.paddingOf(context),
      );
    });
    _portal.show();
  }

  void _close() {
    if (_portal.isShowing) _portal.hide();
  }

  void _pick(CanvasWheelItem item) {
    _close();
    final tool = item.tool;
    if (tool != null) {
      widget.onToolChanged(tool);
    } else {
      widget.onPasteImageAt(_world);
    }
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _portal,
    overlayChildBuilder: (context) => CanvasToolWheel(
      center: _center,
      highlight: _highlight,
      tool: widget.tool,
      shapeKind: widget.shapeKind,
      canDraw: widget.canDraw,
      onPick: _pick,
      onDismiss: _close,
    ),
    child: Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _down,
      onPointerMove: _move,
      onPointerUp: _up,
      onPointerCancel: _up,
      child: const SizedBox.expand(),
    ),
  );
}
