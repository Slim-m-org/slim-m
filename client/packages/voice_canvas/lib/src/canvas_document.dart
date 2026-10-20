// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What a canvas surface holds: the spatial index, the camera, and the side
/// table [CanvasScene] deliberately does not carry.
///
/// A [ChangeNotifier] rather than anything Riverpod-shaped, and that is a
/// correctness property rather than a preference: a provider's value is not
/// observable until the event loop turns, so a stream physically cannot
/// deliver inside the frame that produced it. Painters take this as their
/// `repaint` listenable and no widget rebuilds when the camera moves.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'canvas_board.dart';
import 'canvas_external_pointers.dart';
import 'canvas_paint_order.dart';
import 'canvas_removed_ids.dart';
import 'canvas_scene.dart';
import 'canvas_snap.dart';
import 'canvas_stroke.dart';

export 'canvas_stroke.dart';

part 'canvas_document_board.dart';
part 'canvas_document_queries.dart';
part 'canvas_document_selection.dart';

/// The document: index, camera, strokes, and dedupe by id.
class CanvasDocument extends ChangeNotifier {
  CanvasDocument();

  final CanvasScene scene = CanvasScene();

  /// Null past a removal or a clear: the slot address stays reserved
  /// ([UniformGrid] never renumbers) but the stroke itself is freed, which is
  /// the largest memory win available since a `Path` and its points dominate
  /// this package's footprint.
  final List<CanvasStroke?> _strokes = <CanvasStroke?>[];
  final Map<String, int> _slotById = <String, int>{};
  final PaintOrderCache _paintOrder = PaintOrderCache();
  final RemovedIds _removed = RemovedIds();

  Camera _camera = const Camera();
  Size _viewport = Size.zero;
  ui.Rect? _board;
  bool _atFit = true;

  /// True for exactly as long as [setCamera] is actively pinning the camera
  /// to `worldLimit` - the only feedback a person gets that panning or
  /// zooming stopped because the bounded world ended, not because
  /// something broke. Never flips for [setViewport]'s own re-clamp on a
  /// resize, which is not a gesture anyone is pushing against.
  final ValueNotifier<bool> worldEdgeHit = ValueNotifier<bool>(false);

  /// Pointers `CanvasSurface` itself never receives a down event for - see
  /// `canvas_external_pointers.dart`'s own doc.
  final externalPointers = CanvasExternalPointers();

  /// Bumped whenever the set of objects changes, never when the camera moves,
  /// so an announcement can be rebuilt on content without firing at pan rate.
  final ValueNotifier<int> objectCount = ValueNotifier<int>(0);

  /// How many live objects the board cannot hold whole; see [idsOutsideBoard].
  final ValueNotifier<int> outsideBoardCount = ValueNotifier<int>(0);
  final Set<String> _outsideIds = {};

  /// The one object currently selected for a resize or reorder, or null.
  /// A document-level notifier rather than caller-held state, the same
  /// reason [objectCount] is: the selection painter needs to repaint on a
  /// change here with no widget rebuild in between, the render-loop rule
  /// this whole package exists to keep.
  final ValueNotifier<String?> selectedObjectId = ValueNotifier<String?>(null);

  /// The one object this client's own pointer is currently dragging or
  /// resizing, or null - a narrower, shorter-lived thing than
  /// [selectedObjectId], which stays set for as long as the Move tool holds
  /// a selection. `StrokePainter` reads this to decide which image earns
  /// the app layer's `AppShadows.float` treatment (named here only, this
  /// package carries no design-system dependency, so the shadow itself
  /// arrives as a plain value), a shadow only while an object is literally
  /// off the plane rather than for as long as it merely sits selected.
  final ValueNotifier<String?> elevatedObjectId = ValueNotifier<String?>(null);

  /// Alignment guides of a drag or resize that is snapping right now.
  final ValueNotifier<List<SnapGuide>> snapGuides = ValueNotifier(const []);

  /// Whether moves and resizes snap to the grid; set by the viewer, per device.
  final ValueNotifier<bool> snapToGrid = ValueNotifier<bool>(false);

  Camera get camera => _camera;
  Size get viewport => _viewport;

  /// Slots the last cull kept, in paint order.
  List<int> get paintOrder => _paintOrder.order(
        slotCount: _strokes.length,
        isAlive: (slot) => _strokes[slot]?.alive ?? false,
        compare: comparePaintOrder,
        visible: scene.visible,
      );

  /// Adds a stroke, or returns the slot it already occupies, or refuses one
  /// this document has already been told to drop.
  ///
  /// Dedupe by id is what makes every fetch path safe to repeat: place is
  /// idempotent server-side, so a duplicate from a pan, a live frame or a
  /// reconnect is a no-op here rather than a second mark. The
  /// removed-ids check (`RemovedIds`) is what stops a viewport read that was already in
  /// flight when a removal landed from resurrecting it, permanently, with
  /// nothing later re-delivering the erase.
  int? applyPlaced(CanvasStrokeInput input) {
    if (_removed.contains(input.id)) return null;
    final known = _slotById[input.id];
    if (known != null) {
      final existing = _strokes[known];
      // A duplicate naming a slot this document has since freed is refused.
      if (existing == null) return null;
      // A stroke given up as failed whose commit did land comes back.
      if (!existing.alive) {
        existing.alive = true;
        objectCount.value = objectCount.value + 1;
      }
      existing
        ..zIndex = input.zIndex
        ..seq = input.seq;
      _paintOrder.markDirty();
      return known;
    }
    final path = Path();
    final points = Float32List(input.points.length);
    for (var i = 0; i + 1 < input.points.length; i += 2) {
      final px = input.points[i];
      final py = input.points[i + 1];
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
      points[i] = px + input.x;
      points[i + 1] = py + input.y;
    }
    if (input.points.length == 2) {
      path.lineTo(input.points[0], input.points[1]);
    }
    final slot = scene.add(
      input.x,
      input.y,
      input.x + input.w,
      input.y + input.h,
    );
    // `scene.add` hands out a dense slot in lockstep with `_strokes`.
    _strokes.add(
      CanvasStroke(
        id: input.id,
        x: input.x,
        y: input.y,
        path: path,
        points: points,
        width: input.width,
        colorKey: input.colorKey,
        zIndex: input.zIndex,
        seq: input.seq,
        authorId: input.authorId,
        kind: input.kind,
        w: input.w,
        h: input.h,
        attachmentId: input.attachmentId,
        text: input.text,
        shapeKind: input.shapeKind,
      ),
    );
    _slotById[input.id] = slot;
    _trackOutside(_strokes[slot]);
    objectCount.value = objectCount.value + 1;
    _paintOrder.markDirty();
    return slot;
  }

  /// The bounds a live object currently occupies, or null if [id] is unknown
  /// or has been removed. What [moveObject]'s caller needs to compute a drag
  /// delta, and what an undo needs to restore a move's own original box.
  ({double x, double y, double w, double h})? objectBounds(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) return null;
    return (x: stroke.x, y: stroke.y, w: stroke.w, h: stroke.h);
  }

  /// Repositions a live object to a new box, in place - a stroke's own points
  /// move with it, so a moved stroke still hit-tests against its drawn shape
  /// rather than its old one. Returns false if [id] is unknown or has been
  /// removed.
  ///
  /// **Called once per pointer event for the whole of a drag or a resize**,
  /// which is what every choice here is about. It used to free the grid slot
  /// and insert a fresh one, allocating a replacement [CanvasStroke], a fresh
  /// `Float32List` of every point, and a shifted [Path] each time. The grid
  /// never renumbers or reuses a parked slot, so the remove-then-add also
  /// leaked one slot per pointer event, for the session: a single drag across
  /// a screen leaked a few hundred, and every later linear cull walked all of
  /// them.
  ///
  /// Now [UniformGrid.move] keeps the slot, the points are shifted in place,
  /// and the object keeps its identity. Only [path] is still reallocated,
  /// because `dart:ui` has no in-place translate.
  ///
  /// Applies the box exactly as given: a gesture holds it to the board with
  /// [boxOnBoard] first, so an undo, a rollback or a remote move can put an
  /// object where the server has it.
  bool moveObject(String id, double x, double y, double w, double h) {
    final slot = _slotById[id];
    if (slot == null) return false;
    final stroke = _strokes[slot];
    if (stroke == null || !stroke.alive) return false;
    final dx = x - stroke.x;
    final dy = y - stroke.y;
    if (dx == 0 && dy == 0 && w == stroke.w && h == stroke.h) return true;
    final points = stroke.points;
    for (var i = 0; i < points.length; i++) {
      points[i] += i.isEven ? dx : dy;
    }
    scene.move(slot, x, y, x + w, y + h);
    stroke
      ..x = x
      ..y = y
      ..w = w
      ..h = h
      ..path = stroke.path.shift(Offset(dx, dy));
    if (_board != null) _trackOutside(stroke);
    return true;
  }

  /// Attaches a decoded bitmap to a live [CanvasObjectKind.image] object.
  ///
  /// [image] is disposed immediately, rather than attached, if [id] is no
  /// longer alive by the time its decode finishes - the race between a fetch
  /// in flight and a removal landing first - since nothing else would ever
  /// free bytes nobody can reach again.
  void setImageBitmap(String id, ui.Image image) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) {
      image.dispose();
      return;
    }
    stroke.image = image;
    stroke.imageLoadFailed = false;
    notifyListeners();
  }

  /// Marks a live [CanvasObjectKind.image] object as one whose bytes could
  /// not be fetched or decoded, so the painter draws a placeholder instead
  /// of leaving it blank. A no-op if [id] is unknown, dead, or already
  /// carries a bitmap - a hydration failure racing behind a fetch that
  /// already landed must not blank out a real image.
  void markImageLoadFailed(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive || stroke.image != null) return;
    stroke.imageLoadFailed = true;
    notifyListeners();
  }

  /// Detaches and disposes a live object's decoded bitmap, if it holds one,
  /// without removing the object itself.
  ///
  /// The one caller is the app layer's bounded decode cache: evicting an
  /// off-budget bitmap has to free the memory without forgetting the
  /// object, which would need a real removal op nobody sent. The object
  /// simply stops painting until it is fetched and hydrated again, the same
  /// as one still waiting on its first decode.
  void evictImageBitmap(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    final image = stroke?.image;
    if (image == null) return;
    stroke!.image = null;
    image.dispose();
    notifyListeners();
  }

  /// Marks a stroke as never having landed.
  ///
  /// A different thing from [removeObject]: this means "this commit never
  /// landed", not "this was removed", and the grid keeps the slot rather
  /// than freeing it, since a failed commit never occupied a real object's
  /// address the server could later name.
  void kill(String id) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) return;
    stroke.alive = false;
    _trackOutside(stroke);
    objectCount.value = objectCount.value - 1;
    _paintOrder.markDirty();
  }

  /// Removes a placed object by id, or records the id as removed even if
  /// this document never held it - the in-flight-viewport-page race the
  /// removal design exists to close.
  ///
  /// A no-op on an id already removed or never placed at all, so a batched
  /// remove op replaying an id twice, or naming one this pane never
  /// fetched, costs nothing.
  void removeObject(String id) {
    _removed.add(id);
    final slot = _slotById[id];
    if (slot != null) _freeSlot(slot);
  }

  /// Removes every stroke placed at or below [beforeSeq].
  ///
  /// The `0 <` guard spares a locally drawn stroke, which carries `seq: 0`
  /// until the server confirms it - without it, a clear in flight would
  /// erase ink as it is drawn, before its own placement is even known.
  ///
  /// [kinds] and [authorId] narrow it the way a scoped clear does; empty and
  /// null match everything.
  void clearBelow(
    int beforeSeq, {
    Set<CanvasObjectKind> kinds = const {},
    String? authorId,
  }) {
    for (var slot = 0; slot < _strokes.length; slot++) {
      final stroke = _strokes[slot];
      if (stroke == null || stroke.seq <= 0 || stroke.seq > beforeSeq) continue;
      if (kinds.isNotEmpty && !kinds.contains(stroke.kind)) continue;
      if (authorId != null && stroke.authorId != authorId) continue;
      _removed.add(stroke.id);
      _freeSlot(slot);
    }
  }

  /// Everyone who authored an object still on the board.
  Set<String> authorIds() => {
        for (final stroke in _strokes)
          if (stroke != null && stroke.alive && stroke.authorId != null)
            stroke.authorId!,
      };

  /// Drops ids from the removed-id tombstone set: a restore, which never
  /// re-materializes a stroke locally since its payload was freed on
  /// removal, so only makes a later fetch of the object able to land again.
  ///
  /// The stale `_slotById` entry has to go too, not only the tombstone:
  /// `applyPlaced` refuses a duplicate naming a slot this document has since
  /// freed regardless of whether the id is still tombstoned, so leaving it
  /// behind would make a restored id un-placeable forever even after the
  /// fetch this method exists to let land.
  void forgetRemoved(Iterable<String> ids) {
    final restored = ids.toSet();
    if (restored.isEmpty) return;
    _removed.removeAll(restored);
    _slotById.removeWhere((id, _) => restored.contains(id));
  }

  /// Empties this document entirely: every stroke, the removed-id
  /// tombstones, and the spatial index. Used only for a hard reset of the
  /// whole canvas pane, never for an ordinary removal or clear - the camera
  /// is deliberately untouched, so a reset does not also throw the person's
  /// pan and zoom away.
  void reset() {
    _disposeImages();
    _strokes.clear();
    _slotById.clear();
    _paintOrder.clear();
    _removed.clear();
    scene.reset();
    _outsideIds.clear();
    outsideBoardCount.value = 0;
    objectCount.value = 0;
  }

  void _freeSlot(int slot) {
    final stroke = _strokes[slot];
    if (stroke == null) return;
    // A dying selection must not stay offered a resize or reorder action.
    if (selectedObjectId.value == stroke.id) selectedObjectId.value = null;
    if (elevatedObjectId.value == stroke.id) elevatedObjectId.value = null;
    scene.remove(slot);
    if (_outsideIds.remove(stroke.id)) {
      outsideBoardCount.value = _outsideIds.length;
    }
    stroke.image?.dispose();
    _strokes[slot] = null;
    objectCount.value = objectCount.value - 1;
    _paintOrder.markDirty();
  }

  void _disposeImages() {
    for (final stroke in _strokes) {
      stroke?.image?.dispose();
    }
  }

  /// Re-culls against the current camera and repaints.
  ///
  /// Separate from [applyPlaced] so a snapshot of several hundred objects
  /// costs one cull and one repaint rather than one of each per object, the
  /// same reason [CanvasScene.add] does not notify.
  void refresh() => _reculled();

  /// Moves the camera, clamped so the view stays inside the bounded world and
  /// the zoom inside the range a viewport read is sized for.
  ///
  /// Silent when the clamp lands on the camera already held, the same guard
  /// [setViewport] keeps and for a sharper reason. This is called once per
  /// pointer event for the whole of a pan or a pinch, and a gesture that runs
  /// into a world edge or a zoom stop keeps resolving to the held camera for
  /// as long as the finger stays down. Every notification from here rebuilds
  /// both presence layers, so those are whole rebuilds of a frame that has
  /// not changed.
  void setCamera(Camera next) {
    final clamped = _clamp(next);
    final board = _board;
    worldEdgeHit.value =
        board == null && (clamped.x != next.x || clamped.y != next.y);
    if (board != null) {
      _atFit = clamped.zoom <= boardFitZoom(board, _viewport) + 1e-9;
    }
    if (clamped == _camera) return;
    _camera = clamped;
    _reculled();
  }

  void setViewport(Size size) {
    if (size == _viewport) return;
    _viewport = size;
    final board = _board;
    _camera =
        board != null && _atFit ? boardFitCamera(board, size) : _clamp(_camera);
    if (board != null) {
      _atFit = _camera.zoom <= boardFitZoom(board, size) + 1e-9;
    }
    _reculled();
  }

  /// The world rectangle currently on screen.
  Rect get worldView => Rect.fromLTWH(
        _camera.x,
        _camera.y,
        _viewport.width / _camera.zoom,
        _viewport.height / _camera.zoom,
      );

  Camera _clamp(Camera next) {
    final board = _board;
    if (board != null) return clampCameraToBoard(next, board, _viewport);
    final zoom = next.zoom.clamp(minZoom, maxZoom);
    final w = _viewport.width / zoom;
    final h = _viewport.height / zoom;
    final maxX = math.max(-worldLimit, worldLimit - w);
    final maxY = math.max(-worldLimit, worldLimit - h);
    return Camera(
      x: next.x.clamp(-worldLimit, maxX),
      y: next.y.clamp(-worldLimit, maxY),
      zoom: zoom,
    );
  }

  void _reculled() {
    final board = _board;
    final view = board == null ? worldView : worldView.intersect(board);
    scene.setViewport(view.left, view.top, view.right, view.bottom);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposeImages();
    objectCount.dispose();
    outsideBoardCount.dispose();
    selectedObjectId.dispose();
    elevatedObjectId.dispose();
    snapGuides.dispose();
    snapToGrid.dispose();
    worldEdgeHit.dispose();
    scene.dispose();
    super.dispose();
  }
}
