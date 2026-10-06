// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keyboard-only access to a module scene's painted grid.
///
/// `docs/BACKLOG.md`'s "drivable by keyboard, never a pointer-only
/// immediate-mode surface" bar was written for the Voice Canvas, but a module
/// scene is the same shape of problem: cells are pixels a `CustomPainter`
/// drew, not focusable widgets, so a mouse or a finger was the only way in.
///
/// This is a generic host capability rather than a per-module opt-in: the one
/// addressable-grid shape a scene can have (`CellsOp.tap`/`cols`/`rows`) is
/// already part of the wire contract every module emits through, in
/// `scene/1` itself, so the host can offer arrow-key navigation and
/// enter/space activation for any scene that has one, with nothing a module
/// author has to declare or opt into. A scene with no such grid (buttons and
/// text only) simply has nothing here to move a cursor across.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';
import 'module_scene_painter.dart';

class SceneKeyboardGrid extends StatefulWidget {
  const SceneKeyboardGrid({
    super.key,
    required this.scene,
    required this.size,
    required this.onActivate,
    required this.child,
    this.focusNode,
  });

  final ModuleScene scene;

  /// The painted box, so the highlight scales the way the painter does.
  final Size size;

  /// Called with `"$tap:row,col"`, the same action a tapped cell reports.
  final ValueChanged<String> onActivate;

  final Widget child;

  /// Given rather than always created internally so a caller - a test,
  /// mainly - can drive focus onto this grid directly rather than through a
  /// pointer event.
  final FocusNode? focusNode;

  @override
  State<SceneKeyboardGrid> createState() => _SceneKeyboardGridState();
}

class _SceneKeyboardGridState extends State<SceneKeyboardGrid> {
  FocusNode? _ownedFocusNode;
  FocusNode get _focusNode =>
      widget.focusNode ??
      (_ownedFocusNode ??= FocusNode(debugLabel: 'Module scene grid'));
  int _row = 0;
  int _col = 0;
  bool _hasFocus = false;

  /// The one grid a keyboard can address: the first tappable [CellsOp], the
  /// same op [sceneTapAction] would answer a tap on a cell with.
  CellsOp? get _grid {
    for (final op in widget.scene.ops) {
      if (op is CellsOp && op.tap != null && op.cols > 0 && op.rows > 0) {
        return op;
      }
    }
    return null;
  }

  int _clampedRow(CellsOp grid) => _row.clamp(0, grid.rows - 1);
  int _clampedCol(CellsOp grid) => _col.clamp(0, grid.cols - 1);

  @override
  void dispose() {
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  void _move(int dRow, int dCol) {
    final grid = _grid;
    if (grid == null) return;
    setState(() {
      _row = (_clampedRow(grid) + dRow).clamp(0, grid.rows - 1);
      _col = (_clampedCol(grid) + dCol).clamp(0, grid.cols - 1);
    });
  }

  void _activate() {
    final grid = _grid;
    if (grid == null) return;
    widget.onActivate('${grid.tap}:${_clampedRow(grid)},${_clampedCol(grid)}');
  }

  void _claimFocus(PointerDownEvent event) {
    final hit = HitTestResult();
    WidgetsBinding.instance.hitTestInView(hit, event.position, event.viewId);
    final onField = hit.path.any((entry) => entry.target is RenderEditable);
    if (!onField) _focusNode.requestFocus();
  }

  KeyEventResult _onKeyEvent(FocusNode node, KeyEvent event) {
    // A key from a field inside the scene bubbles here; only the grid's own focus is ours.
    if (_grid == null || event is! KeyDownEvent || !node.hasPrimaryFocus) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        _move(-1, 0);
      case LogicalKeyboardKey.arrowDown:
        _move(1, 0);
      case LogicalKeyboardKey.arrowLeft:
        _move(0, -1);
      case LogicalKeyboardKey.arrowRight:
        _move(0, 1);
      case LogicalKeyboardKey.enter ||
          LogicalKeyboardKey.numpadEnter ||
          LogicalKeyboardKey.space:
        _activate();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final grid = _grid;
    return Focus(
      focusNode: _focusNode,
      onFocusChange: (has) => setState(() => _hasFocus = has),
      onKeyEvent: _onKeyEvent,
      child: Listener(
        // Lets a click hand off to the keyboard: tap a cell, then use arrows.
        onPointerDown: _claimFocus,
        child: Semantics(
          label: grid == null
              ? null
              : 'Scene grid. Arrow keys move, enter or space selects.',
          child: Stack(
            children: [
              widget.child,
              if (grid != null && _hasFocus) _highlight(grid, tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _highlight(CellsOp grid, AppTokens tokens) {
    final sx = widget.scene.width == 0
        ? 1.0
        : widget.size.width / widget.scene.width;
    final sy = widget.scene.height == 0
        ? 1.0
        : widget.size.height / widget.scene.height;
    final rect = cellsGridRect(grid, widget.scene, sx, sy);
    final cellW = rect.width / grid.cols;
    final cellH = rect.height / grid.rows;
    return Positioned(
      left: rect.left + _clampedCol(grid) * cellW,
      top: rect.top + _clampedRow(grid) * cellH,
      width: cellW,
      height: cellH,
      child: IgnorePointer(
        child: DecoratedBox(
          decoration: BoxDecoration(
            border: Border.all(color: tokens.focusRing, width: 2),
          ),
        ),
      ),
    );
  }
}
