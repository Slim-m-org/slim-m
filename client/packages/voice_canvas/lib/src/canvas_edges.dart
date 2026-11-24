// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The edges a canvas holds (decision 0137): connections between objects.
///
/// Kept apart from the slot scene on purpose. An edge has no box of its own to index: it is
/// routed from the boxes its ends are drawn at right now, so it follows a local drag, a resize
/// and a remote preview with nothing to invalidate, and it never enters the spatial grid.
library;

import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;

import 'canvas_document.dart';
import 'canvas_edge_route.dart';
import 'canvas_edge_spec.dart';
import 'canvas_removed_ids.dart';

/// An edge as the wire describes it, with no JSON and no api types.
@immutable
class CanvasEdgeInput {
  const CanvasEdgeInput({
    required this.id,
    required this.seq,
    required this.zIndex,
    required this.spec,
    required this.hull,
    this.authorId,
  });

  final String id;
  final int seq;
  final int zIndex;
  final CanvasEdgeSpec spec;

  /// The box the server stored, which only a region read ever consults.
  final Rect hull;
  final String? authorId;
}

/// One live edge.
class CanvasEdge {
  CanvasEdge(CanvasEdgeInput input)
      : id = input.id,
        seq = input.seq,
        zIndex = input.zIndex,
        authorId = input.authorId,
        spec = input.spec,
        wireHull = input.hull;

  final String id;
  int seq;
  int zIndex;
  final String? authorId;
  CanvasEdgeSpec spec;
  Rect wireHull;

  /// False once a commit failed for good.
  bool alive = true;
}

/// An edge being drawn: the end that is fixed and where the other one is now.
@immutable
class EdgeDraft {
  const EdgeDraft({
    required this.fromObjectId,
    required this.fromSide,
    required this.pointer,
    this.targetObjectId,
    this.targetSide = EdgeSide.auto,
  });

  final String fromObjectId;
  final EdgeSide fromSide;
  final Offset pointer;

  /// The object the pointer is over, which the edge would attach to on release.
  final String? targetObjectId;
  final EdgeSide targetSide;
}

/// The edges of one [CanvasDocument].
class CanvasEdges {
  CanvasEdges(this._document);

  final CanvasDocument _document;
  final Map<String, CanvasEdge> _byId = {};
  final Map<String, Set<String>> _byEnd = {};
  final RemovedIds _removed = RemovedIds();

  /// The id the document has selected, which is an edge's when one is.
  String? get selectedId => _document.selectedObjectId.value;

  void _release(String id) {
    if (selectedId == id) _document.selectedObjectId.value = null;
  }

  /// The edge being drawn right now.
  final ValueNotifier<EdgeDraft?> draft = ValueNotifier<EdgeDraft?>(null);

  /// The edge whose label is being edited in place, or null; the keyboard, a double click and the bar all set it.
  final ValueNotifier<String?> labelEdit = ValueNotifier<String?>(null);

  /// The object a keyboard or menu connection starts from, while its target is being picked.
  final ValueNotifier<String?> connectFrom = ValueNotifier<String?>(null);

  /// Takes a key while [connectFrom] is set; the app wires the keys it means.
  bool Function(LogicalKeyboardKey key)? pickKey;

  /// The object whose four side dots show, because it is hovered, selected or the Connect tool is armed.
  final ValueNotifier<String?> dotsOn = ValueNotifier<String?>(null);

  /// An edge that is selected and live, for the bar and the keyboard.
  CanvasEdge? get selected => liveEdge(selectedId);

  CanvasEdge? liveEdge(String? id) {
    final edge = id == null ? null : _byId[id];
    return edge != null && edge.alive ? edge : null;
  }

  /// The objects [edgeId] hangs on, or nothing when it is not an edge held here.
  Iterable<String> endIdsOf(String edgeId) =>
      _byId[edgeId]?.spec.attachedIds ?? const <String>[];

  bool isAlive(String id) => liveEdge(id) != null;
  bool knows(String id) => _byId.containsKey(id);
  bool wasRemoved(String id) => _removed.contains(id);
  int get liveCount => _byId.values.where((e) => e.alive).length;

  /// Live edges in paint order, edges only: lowest `zIndex` first, then `seq`, then id.
  List<CanvasEdge> get inPaintOrder => [
        for (final edge in _byId.values)
          if (edge.alive) edge,
      ]..sort((a, b) {
          final byZ = a.zIndex.compareTo(b.zIndex);
          if (byZ != 0) return byZ;
          final bySeq = a.seq.compareTo(b.seq);
          return bySeq != 0 ? bySeq : a.id.compareTo(b.id);
        });

  /// Live edges attached to [objectId].
  List<CanvasEdge> attachedTo(String objectId) => [
        for (final id in _byEnd[objectId] ?? const <String>{})
          if (liveEdge(id) case final edge?) edge,
      ];

  Rect? _boxOf(String id) {
    final bounds = _document.objectBounds(id);
    return bounds == null
        ? null
        : Rect.fromLTWH(bounds.x, bounds.y, bounds.w, bounds.h);
  }

  /// The box an attached end is drawn at, or null while it is not held.
  Rect? boxOf(String objectId) => _boxOf(objectId);

  /// The route of [edge] over the boxes its ends are drawn at, or null while an end is not held yet.
  EdgeRoute? routeOf(CanvasEdge edge) {
    Rect? box(EdgeEndSpec end) =>
        end is AttachedEnd ? _boxOf(end.objectId) : null;
    return routeEdge(edge.spec, box(edge.spec.from), box(edge.spec.to));
  }

  /// The hull [edge] has right now: from its held ends, else the one the server stored.
  Rect hullOf(CanvasEdge edge) {
    final parts = <Rect>[];
    for (final end in [edge.spec.from, edge.spec.to]) {
      switch (end) {
        case FreeEnd(:final point):
          parts.add(Rect.fromLTWH(point.dx, point.dy, 0, 0));
        case AttachedEnd(:final objectId):
          final box = _boxOf(objectId);
          if (box == null) return edge.wireHull;
          parts.add(box);
      }
    }
    final h = edgeHull(parts);
    return Rect.fromLTWH(h.x, h.y, h.w, h.h);
  }

  /// Adds an edge, or refreshes the one held; null for one this document was told to drop.
  /// [overwrite] is for snapshot reads, which are authoritative for the spec.
  int? applyPlaced(
    CanvasEdgeInput input, {
    bool overwrite = false,
    int? snapshotSeq,
  }) {
    if (_removed.contains(input.id)) {
      final removedAt = _removed.seqOf(input.id);
      final restored =
          snapshotSeq != null && removedAt != null && snapshotSeq > removedAt;
      if (!restored) return null;
      _removed.removeAll({input.id});
    }
    final held = _byId[input.id];
    if (held == null) {
      final reflected = _document.reflectedSeq;
      if (!overwrite &&
          reflected != null &&
          input.seq > 0 &&
          input.seq <= reflected) {
        return null;
      }
      _add(CanvasEdge(input));
      _document.refresh();
      return 0;
    }
    if (!held.alive) held.alive = true;
    if (overwrite || input.seq == 0 || input.seq > held.seq) {
      held
        ..zIndex = input.zIndex
        ..seq = input.seq;
    }
    held.wireHull = input.hull;
    if (overwrite && held.spec != input.spec) _setSpec(held, input.spec);
    _document.refresh();
    return 0;
  }

  void _add(CanvasEdge edge) {
    _byId[edge.id] = edge;
    _index(edge);
  }

  void _index(CanvasEdge edge) {
    for (final id in edge.spec.attachedIds) {
      (_byEnd[id] ??= <String>{}).add(edge.id);
    }
  }

  void _unindex(CanvasEdge edge) {
    for (final id in edge.spec.attachedIds) {
      _byEnd[id]?.remove(edge.id);
      if (_byEnd[id]?.isEmpty ?? false) _byEnd.remove(id);
    }
  }

  void _setSpec(CanvasEdge edge, CanvasEdgeSpec spec) {
    _unindex(edge);
    edge.spec = spec;
    _index(edge);
  }

  /// Applies the props an `edit` wrote: an absent key keeps its value and `null` deletes it.
  bool applyEdited(String id, Map<String, Object?> props) {
    final edge = liveEdge(id);
    if (edge == null) return false;
    final merged = {...edge.spec.toProps()};
    for (final entry in props.entries) {
      if (entry.value == null) {
        merged.remove(entry.key);
      } else {
        merged[entry.key] = entry.value;
      }
    }
    final next = CanvasEdgeSpec.fromProps(merged);
    if (next == null || next == edge.spec) return false;
    _setSpec(edge, next);
    _document.refresh();
    return true;
  }

  /// Replaces the spec of [id] with the whole props a server frame carries; a key it lacks is gone.
  bool replaceProps(String id, Map<String, Object?> props) {
    final edge = liveEdge(id);
    final next = edge == null ? null : CanvasEdgeSpec.fromProps(props);
    if (edge == null || next == null || next == edge.spec) return false;
    _setSpec(edge, next);
    _document.refresh();
    return true;
  }

  /// Sets the paint order of [id]; false when it is not a live edge.
  bool setZIndex(String id, int zIndex) {
    final edge = liveEdge(id);
    if (edge == null) return false;
    edge.zIndex = zIndex;
    _document.refresh();
    return true;
  }

  /// An object was removed: if it is an edge it goes, and every edge attached to it goes with it, tombstoned at [seq].
  void objectRemoved(String id, int? seq) {
    final attached = List<String>.of(_byEnd[id] ?? const <String>{});
    for (final edgeId in [id, ...attached]) {
      final edge = _byId.remove(edgeId);
      if (edge == null) continue;
      _unindex(edge);
      _removed.add(edgeId, seq: seq);
      _release(edgeId);
    }
  }

  /// Frees [id], and every edge attached to it, without tombstoning: a snapshot that lacks them says the document drifted.
  void objectDropped(String id) {
    final attached = List<String>.of(_byEnd[id] ?? const <String>{});
    for (final edgeId in [id, ...attached]) {
      final edge = _byId.remove(edgeId);
      if (edge == null) continue;
      _unindex(edge);
      _release(edgeId);
    }
  }

  /// A clear took [clearedIds]: the edges it removed itself, and the ones that lost a held end.
  void cleared(
    Set<String> clearedIds,
    int beforeSeq,
    Set<CanvasObjectKind> kinds,
    String? authorId,
    int? opSeq,
    Set<String> spare,
  ) {
    final wantsEdges = kinds.isEmpty || kinds.contains(CanvasObjectKind.edge);
    for (final edge in List<CanvasEdge>.of(_byId.values)) {
      final ownMatch = wantsEdges &&
          edge.seq > 0 &&
          edge.seq <= beforeSeq &&
          (authorId == null || edge.authorId == authorId) &&
          !spare.contains(edge.id);
      final lostEnd = edge.spec.attachedIds.any(clearedIds.contains);
      if (ownMatch || lostEnd) {
        _byId.remove(edge.id);
        _unindex(edge);
        _removed.add(edge.id, seq: opSeq);
        _release(edge.id);
      }
    }
  }

  void forgetRemoved(Set<String> ids) => _removed.removeAll(ids);

  void confirmRemoved(Iterable<String> ids, int seq) =>
      _removed.confirm(ids, seq);

  /// Marks an edge whose commit never landed.
  void kill(String id) {
    final edge = _byId[id];
    if (edge == null || !edge.alive) return;
    edge.alive = false;
    _release(id);
    _document.refresh();
  }

  void reset() {
    _byId.clear();
    _byEnd.clear();
    _removed.clear();
    draft.value = null;
    dotsOn.value = null;
    labelEdit.value = null;
    connectFrom.value = null;
  }

  void dispose() {
    pickKey = null;
    draft.dispose();
    dotsOn.dispose();
    labelEdit.dispose();
    connectFrom.dispose();
  }
}
