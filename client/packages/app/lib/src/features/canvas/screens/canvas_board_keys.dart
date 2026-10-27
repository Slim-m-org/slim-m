// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The board as one keyboard stop: arrows pan, plus and minus zoom, 0 fits,
/// ] and [ step the selection through what is in view, and Enter places with
/// the armed tool or opens the selected object's actions.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_text_focus.dart';

/// The share of the view one arrow press pans.
const double _panStep = 0.15;

/// The zoom change of one plus or minus press.
const double _zoomStep = 1.25;

class CanvasBoardKeys extends StatefulWidget {
  const CanvasBoardKeys({
    super.key,
    required this.document,
    required this.tool,
    required this.onOpenActions,
    required this.onOpenToolWheel,
    required this.onPlaceNote,
    required this.onPlaceShape,
    this.focusNode,
    required this.child,
  });

  final CanvasDocument document;

  /// The armed tool; null while nothing on the board takes a key.
  final CanvasTool? tool;

  /// Opens the selected object's own menu, the same one a right-click opens.
  final ValueChanged<String> onOpenActions;

  /// Opens the tool wheel, the keyboard's way to what a right-click hold opens.
  final VoidCallback onOpenToolWheel;

  /// Places with the note or shape tool at a world point.
  final ValueChanged<Offset> onPlaceNote;
  final ValueChanged<Offset> onPlaceShape;

  /// Optional external node so the pane can return focus to the board after a sheet or inline editor closes.
  final FocusNode? focusNode;

  final Widget child;

  @override
  State<CanvasBoardKeys> createState() => _CanvasBoardKeysState();
}

class _CanvasBoardKeysState extends State<CanvasBoardKeys> {
  bool _focused = false;

  /// Drawn only for keyboard focus: the board takes focus as the pane opens, where a ring would be noise.
  bool _ring = false;

  FocusNode? _ownNode;
  FocusNode get _node =>
      widget.focusNode ?? (_ownNode ??= FocusNode(debugLabel: 'canvas board'));

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocusChanged);
    FocusManager.instance.addHighlightModeListener(_onHighlightMode);
  }

  @override
  void didUpdateWidget(covariant CanvasBoardKeys oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.focusNode != widget.focusNode) {
      (oldWidget.focusNode ?? _ownNode)?.removeListener(_onFocusChanged);
      if (widget.focusNode != null) {
        _ownNode?.dispose();
        _ownNode = null;
      }
      _node.addListener(_onFocusChanged);
      _onFocusChanged();
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightMode);
    _node.removeListener(_onFocusChanged);
    _ownNode?.dispose();
    super.dispose();
  }

  // Primary focus only: focus inside a field below the board is not the board's stop.
  void _onFocusChanged() {
    final focused = _node.hasPrimaryFocus;
    if (focused == _focused) return;
    setState(() {
      _focused = focused;
      // A Tab or arrow that moved focus here is still down when this runs; a held shortcut modifier is not.
      _ring =
          focused &&
          HardwareKeyboard.instance.logicalKeysPressed.any(
            _navigationKeys.contains,
          );
    });
  }

  // A click or touch anywhere puts the app back in pointer mode, which hides a ring the keyboard drew.
  void _onHighlightMode(FocusHighlightMode mode) {
    if (mode == FocusHighlightMode.touch && _ring && mounted) {
      setState(() => _ring = false);
    }
  }

  static final _navigationKeys = {
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
  };

  CanvasDocument get _document => widget.document;

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (textInputHasFocus()) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (keys.isControlPressed || keys.isMetaPressed || keys.isAltPressed) {
      return KeyEventResult.ignored;
    }
    final view = _document.viewport;
    final key = event.logicalKey;
    final once = event is KeyDownEvent;
    final handled = switch (key) {
      LogicalKeyboardKey.arrowLeft => _pan(-view.width * _panStep, 0),
      LogicalKeyboardKey.arrowRight => _pan(view.width * _panStep, 0),
      LogicalKeyboardKey.arrowUp => _pan(0, -view.height * _panStep),
      LogicalKeyboardKey.arrowDown => _pan(0, view.height * _panStep),
      LogicalKeyboardKey.pageUp => _pan(0, -view.height * 0.8),
      LogicalKeyboardKey.pageDown => _pan(0, view.height * 0.8),
      LogicalKeyboardKey.equal ||
      LogicalKeyboardKey.add ||
      LogicalKeyboardKey.numpadAdd => _zoom(_zoomStep),
      LogicalKeyboardKey.minus ||
      LogicalKeyboardKey.numpadSubtract => _zoom(1 / _zoomStep),
      LogicalKeyboardKey.digit0 || LogicalKeyboardKey.numpad0 => once && _fit(),
      LogicalKeyboardKey.bracketRight => once && _step(1),
      LogicalKeyboardKey.bracketLeft => once && _step(-1),
      LogicalKeyboardKey.enter ||
      LogicalKeyboardKey.numpadEnter => once && _activate(),
      LogicalKeyboardKey.escape => once && _deselect(),
      LogicalKeyboardKey.contextMenu => once && _openMenu(),
      LogicalKeyboardKey.f10 => once && keys.isShiftPressed && _openMenu(),
      _ => false,
    };
    if (handled && !_ring) setState(() => _ring = true);
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  bool _pan(double dx, double dy) {
    final camera = _document.camera;
    _document.setCamera(
      camera.copyWith(
        x: camera.x + dx / camera.zoom,
        y: camera.y + dy / camera.zoom,
      ),
    );
    return true;
  }

  bool _zoom(double factor) {
    final camera = _document.camera;
    final view = _document.viewport;
    _document.setCamera(
      cameraAfterZoom(
        camera,
        focal: Offset(view.width / 2, view.height / 2),
        zoomTarget: camera.zoom * factor,
        zoomFloor: _document.zoomFloor,
      ),
    );
    return true;
  }

  bool _fit() {
    if (_document.board == null) return false;
    _document.fitContent();
    return true;
  }

  /// Moves the selection to the next or previous object in view, in paint order.
  bool _step(int direction) {
    final ids = _document.visibleIds.toList();
    if (ids.isEmpty) return false;
    final current = _document.selectedObjectId.value;
    final at = current == null ? -1 : ids.indexOf(current);
    final entry = direction > 0 ? 0 : ids.length - 1;
    final next = at < 0 ? entry : (at + direction) % ids.length;
    _document.selectedObjectId.value = ids[next];
    return true;
  }

  bool _activate() {
    final centre = _document.worldView.center;
    switch (widget.tool) {
      case CanvasTool.note:
        widget.onPlaceNote(centre);
        return true;
      case CanvasTool.shape:
        widget.onPlaceShape(centre);
        return true;
      case CanvasTool.pen || CanvasTool.eraser || CanvasTool.pan || null:
        final selected = _document.selectedObjectId.value;
        if (selected == null) return _step(1);
        widget.onOpenActions(selected);
        return true;
    }
  }

  /// The context-menu key: the selected object's menu, else the tool wheel.
  bool _openMenu() {
    final selected = _document.selectedObjectId.value;
    if (selected == null) {
      widget.onOpenToolWheel();
    } else {
      widget.onOpenActions(selected);
    }
    return true;
  }

  bool _deselect() {
    if (_document.selectedObjectId.value == null) return false;
    _document.selectedObjectId.value = null;
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Focus(
      focusNode: _node,
      // The pane's own keys bubble up from here, so the board holds focus from the start.
      autofocus: true,
      onKeyEvent: _onKey,
      includeSemantics: false,
      // Its own node with every child kept apart: merged, the board's label swallowed drags on web.
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        focusable: true,
        focused: _focused,
        label: 'Canvas board',
        hint:
            'Arrow keys pan, plus and minus zoom, 0 fits, square brackets '
            'step through objects, Enter opens the selected one, the menu key opens the tool wheel',
        child: DecoratedBox(
          position: DecorationPosition.foreground,
          decoration: BoxDecoration(
            border: _focused && _ring
                ? Border.all(color: tokens.focusRing, width: 2)
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
