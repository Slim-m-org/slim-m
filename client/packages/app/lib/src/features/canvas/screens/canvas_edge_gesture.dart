// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Drawing and reshaping connections with the pointer (decision 0137).
///
/// The select gesture offers every press here first. A press claims it when it lands on a side dot, on an end handle of the selected connection, on a connection itself, or anywhere on an object while the Connect tool is armed.
library;

import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:clock/clock.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart' show AppFonts;
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../providers/providers.dart';
import '../providers/canvas_edge_style.dart';
import 'canvas_edge_placement.dart';
import 'canvas_engine.dart';
import 'canvas_ops_controller.dart';

/// What an end drag is: drawing a new connection from an object, or moving one end of an existing one.
sealed class _Drag {
  const _Drag();
}

class _Draw extends _Drag {
  _Draw(this.fromObjectId, this.fromSide, this.start);

  final String fromObjectId;
  final EdgeSide fromSide;
  final Offset start;
  bool moved = false;
}

class _Reattach extends _Drag {
  _Reattach(this.edgeId, this.isTo, this.before);

  final String edgeId;
  final bool isTo;
  final CanvasEdgeSpec before;

  /// Whether the pointer is somewhere the edge could end up; a drop that would free both ends snaps back.
  bool valid = true;
}

/// How soon a second click on a connection makes a double click.
const _doubleClickWindow = Duration(milliseconds: 400);

/// How far the pointer must travel before a press is a drag, in screen pixels.
const double _dragSlopPx = 6;

/// The kinds a connection may attach to; strokes, edges and media tiles cannot be.
const _attachable = {
  CanvasObjectKind.note,
  CanvasObjectKind.text,
  CanvasObjectKind.shape,
  CanvasObjectKind.image,
  CanvasObjectKind.emoji,
  CanvasObjectKind.tile,
};

/// Whether a connection may attach to an object of [kind].
bool canvasEdgeAttachable(CanvasObjectKind? kind) => _attachable.contains(kind);

class CanvasEdgeGesture {
  CanvasEdgeGesture({
    required this.engine,
    required this.ref,
    required this.channelId,
    required this.tool,
    required this.touch,
    required this.manageCanvas,
  }) {
    document.selectedObjectId.addListener(syncDots);
    document.edges.pickKey = pickKey;
  }

  final CanvasEngine engine;
  final WidgetRef ref;
  final String Function() channelId;
  final CanvasTool Function() tool;
  final bool Function() touch;
  final bool Function() manageCanvas;

  CanvasDocument get document => engine.document;
  CanvasEdges get _edges => document.edges;

  late final CanvasEdgePlacement _placement = CanvasEdgePlacement(
    client: ref.read(apiProvider),
    channelId: channelId(),
    document: document,
    timedOutUntil: () => ref.read(meProvider).valueOrNull?.timedOutUntil,
    authorId: () => ref.read(meProvider).valueOrNull?.id,
    clearedSincePlacement: engine.sync.clearedSincePlacement,
  );

  final _labels = EdgeLabels(fontFamily: AppFonts.sans);
  _Drag? _drag;
  String? _hovered;
  ({String id, DateTime at})? _lastClick;

  bool get active => _drag != null;
  bool get _supported => ref.read(canvasEdgesSupportedProvider);

  void dispose() {
    document.selectedObjectId.removeListener(syncDots);
    document.edges.pickKey = null;
    _labels.dispose();
  }

  bool _mayEdit(CanvasEdge edge) =>
      manageCanvas() ||
      (edge.authorId != null &&
          edge.authorId == ref.read(meProvider).valueOrNull?.id);

  /// The attachable object under [world], topmost first.
  String? _objectAt(Offset world) => hitTestTopmost(
    document,
    world,
    touch: touch(),
    accepts: (stroke) => _attachable.contains(stroke.kind),
  );

  /// The object whose dots show: the hovered one, else the selected one, and only while an object tool is armed.
  void syncDots() {
    final armed = tool() == CanvasTool.pan || tool() == CanvasTool.connect;
    final selected = document.selectedObjectId.value;
    final selectedObject =
        selected != null && _attachable.contains(document.kindOf(selected))
        ? selected
        : null;
    _edges.dotsOn.value = !_supported || !armed
        ? null
        : _hovered ?? selectedObject;
  }

  /// A pointer moved without a button: the object under it shows its dots, which a finger gets from selecting instead.
  void hover(Offset world) {
    if (active) return;
    final mouse = document.lastPointerKind == PointerDeviceKind.mouse;
    _hovered = mouse && _supported ? _objectAt(world) : null;
    syncDots();
  }

  bool get picking => _edges.connectFrom.value != null;
  String? _pickTarget;

  /// Starts the keyboard route: [id] waits for a target, stepped with the bracket keys.
  void beginPick(String id) {
    _pickTarget = null;
    _edges.connectFrom.value = id;
  }

  void cancelPick() {
    _pickTarget = null;
    _edges.connectFrom.value = null;
    _edges.draft.value = null;
  }

  /// A key while a target is being picked: `[` and `]` step, Enter attaches, Escape cancels; true when it was taken.
  bool pickKey(LogicalKeyboardKey key) {
    final from = _edges.connectFrom.value;
    if (from == null) return false;
    if (key == LogicalKeyboardKey.escape) {
      cancelPick();
    } else if (key == LogicalKeyboardKey.bracketRight) {
      _stepPick(from, 1);
    } else if (key == LogicalKeyboardKey.bracketLeft) {
      _stepPick(from, -1);
    } else if (key == LogicalKeyboardKey.enter) {
      unawaited(_finishPick(from));
    } else {
      return false;
    }
    return true;
  }

  void _stepPick(String from, int delta) {
    final targets = [
      for (final id in document.visibleIdsInReadingOrder())
        if (id != from && _attachable.contains(document.kindOf(id))) id,
    ];
    if (targets.isEmpty) return;
    final at = _pickTarget == null ? -1 : targets.indexOf(_pickTarget!);
    final next = targets[(at + delta) % targets.length];
    final box = _edges.boxOf(next);
    _pickTarget = next;
    _edges.draft.value = EdgeDraft(
      fromObjectId: from,
      fromSide: EdgeSide.auto,
      pointer: box?.center ?? Offset.zero,
      targetObjectId: next,
    );
  }

  Future<void> _finishPick(String from) async {
    final target = _pickTarget;
    cancelPick();
    if (target == null) return;
    final style = ref.read(canvasActiveEdgeStyleProvider);
    final placed = await _placement.place(
      CanvasEdgeSpec(
        from: AttachedEnd(from),
        to: AttachedEnd(target),
        arrow: style.arrow,
        colorKey: style.colorKey,
      ),
      onError: engine.reportError,
    );
    if (placed != null) {
      engine.ops.recordDraw([placed.id]);
      document.selectedObjectId.value = placed.id;
    }
  }

  /// A press at [world]; true when it belongs to a connection and the select gesture must stand down.
  bool start(Offset world) {
    if (!_supported) return false;
    final connect = tool() == CanvasTool.connect;
    final zoom = document.camera.zoom;
    if (!connect && _startOnHandle(world, zoom)) return true;
    if (_startOnDot(world, zoom, connect: connect)) return true;
    if (connect) return _startOnObject(world);
    return _selectEdgeAt(world);
  }

  bool _startOnHandle(Offset world, double zoom) {
    final hit = _edges.hitEndHandle(world, zoom: zoom, touch: touch());
    final edge = hit == null ? null : _edges.liveEdge(hit.edgeId);
    if (hit == null || edge == null || !_mayEdit(edge)) return false;
    _drag = _Reattach(edge.id, hit.isTo, edge.spec);
    document.elevatedObjectId.value = null;
    return true;
  }

  bool _startOnDot(Offset world, double zoom, {required bool connect}) {
    final id = _edges.dotsOn.value;
    final box = id == null ? null : _edges.boxOf(id);
    if (id == null || box == null) return false;
    final side = sideDotAt(box, world, zoom: zoom, touch: touch());
    if (side == null) return false;
    // A press in the body of an object is a move; a dot is grabbed on or outside the border.
    if (!connect && box.deflate(sideDotSizePx / 2 / zoom).contains(world)) {
      return false;
    }
    _beginDraw(id, side, world);
    return true;
  }

  bool _startOnObject(Offset world) {
    final id = _objectAt(world);
    if (id == null) return false;
    _beginDraw(id, EdgeSide.auto, world);
    return true;
  }

  void _beginDraw(String id, EdgeSide side, Offset world) {
    _drag = _Draw(id, side, world);
    _edges.draft.value = EdgeDraft(
      fromObjectId: id,
      fromSide: side,
      pointer: world,
    );
  }

  /// A press on a connection selects it, unless an object sits above it.
  bool _selectEdgeAt(Offset world) {
    if (hitTestTopmost(document, world, touch: touch()) != null) return false;
    final id = _edges.hitEdge(
      world,
      zoom: document.camera.zoom,
      touch: touch(),
      labelSize: _labels.sizeOf,
    );
    if (id == null) return false;
    document.selectedObjectId.value = id;
    return true;
  }

  void drag(Offset world) {
    switch (_drag) {
      case _Draw draw:
        _dragDraw(draw, world);
      case _Reattach reattach:
        _dragReattach(reattach, world);
      case null:
        break;
    }
  }

  void _dragDraw(_Draw draw, Offset world) {
    final zoom = document.camera.zoom;
    if ((world - draw.start).distance * zoom >= _dragSlopPx) draw.moved = true;
    final target = _objectAt(world);
    final solid = target != null && target != draw.fromObjectId ? target : null;
    final box = solid == null ? null : _edges.boxOf(solid);
    final side = box == null
        ? EdgeSide.auto
        : sideDotAt(box, world, zoom: zoom, touch: touch()) ?? EdgeSide.auto;
    _edges.draft.value = EdgeDraft(
      fromObjectId: draw.fromObjectId,
      fromSide: draw.fromSide,
      pointer: world,
      targetObjectId: solid,
      targetSide: side,
    );
  }

  void _dragReattach(_Reattach drag, Offset world) {
    final target = _objectAt(world);
    final other = drag.isTo ? drag.before.from : drag.before.to;
    final onOther = other is AttachedEnd && other.objectId == target;
    final EdgeEndSpec end;
    if (target != null && !onOther) {
      final box = _edges.boxOf(target);
      final zoom = document.camera.zoom;
      final side = box == null
          ? EdgeSide.auto
          : sideDotAt(box, world, zoom: zoom, touch: touch()) ?? EdgeSide.auto;
      end = AttachedEnd(target, side: side);
    } else {
      end = FreeEnd(world);
    }
    drag.valid = !(end is FreeEnd && other is FreeEnd);
    if (!drag.valid) return;
    _edges.applyEdited(drag.edgeId, {
      (drag.isTo ? 'to' : 'from'): edgeEndToProps(end),
    });
  }

  Future<void> end() async {
    final drag = _drag;
    _drag = null;
    switch (drag) {
      case _Draw draw:
        await _finishDraw(draw);
      case _Reattach reattach:
        await _finishReattach(reattach);
      case null:
        break;
    }
    _edges.draft.value = null;
    syncDots();
  }

  Future<void> _finishDraw(_Draw draw) async {
    final draft = _edges.draft.value;
    _edges.draft.value = null;
    if (draft == null || !draw.moved) return;
    final target = draft.targetObjectId;
    final style = ref.read(canvasActiveEdgeStyleProvider);
    final spec = CanvasEdgeSpec(
      from: AttachedEnd(draw.fromObjectId, side: draw.fromSide),
      to: target == null
          ? FreeEnd(draft.pointer)
          : AttachedEnd(target, side: draft.targetSide),
      arrow: style.arrow,
      colorKey: style.colorKey,
    );
    final placed = await _placement.place(spec, onError: engine.reportError);
    if (placed != null) {
      engine.ops.recordDraw([placed.id]);
      document.selectedObjectId.value = placed.id;
    }
  }

  Future<void> _finishReattach(_Reattach drag) async {
    final edge = _edges.liveEdge(drag.edgeId);
    if (edge == null) return;
    final key = drag.isTo ? 'to' : 'from';
    final now = edge.spec.toProps()[key];
    final was = drag.before.toProps()[key];
    _edges.applyEdited(drag.edgeId, {key: was});
    if (!drag.valid || now.toString() == was.toString()) return;
    await engine.ops.editEdge(drag.edgeId, {key: now});
  }

  void cancel() {
    final drag = _drag;
    _drag = null;
    if (drag is _Reattach) {
      final key = drag.isTo ? 'to' : 'from';
      _edges.applyEdited(drag.edgeId, {key: drag.before.toProps()[key]});
    }
    _edges.draft.value = null;
    syncDots();
  }

  /// A tap that finished without moving: a second tap, or a double click, on the selected connection edits its label.
  void tap(Offset world, PointerDeviceKind kind, String? selectedBefore) {
    final id = document.selectedObjectId.value;
    final edge = _edges.liveEdge(id);
    if (edge == null || !_mayEdit(edge)) return;
    final hit = _edges.hitEdge(
      world,
      zoom: document.camera.zoom,
      touch: touch(),
      labelSize: _labels.sizeOf,
    );
    if (hit != id) return;
    if (kind == PointerDeviceKind.mouse) {
      final last = _lastClick;
      final now = clock.now();
      _lastClick = (id: id!, at: now);
      if (last == null ||
          last.id != id ||
          now.difference(last.at) > _doubleClickWindow) {
        return;
      }
      _lastClick = null;
    } else if (id != selectedBefore) {
      return;
    }
    _edges.labelEdit.value = id;
  }
}
