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
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/painting.dart';

import 'canvas_board.dart';
import 'canvas_external_pointers.dart';
import 'canvas_paint_order.dart';
import 'canvas_removed_ids.dart';
import 'canvas_scene.dart';
import 'canvas_smooth_path.dart';
import 'canvas_snap.dart';
import 'canvas_stroke.dart';
import 'spatial_grid.dart' show CullResult;

export 'canvas_stroke.dart';

part 'canvas_document_board.dart';
part 'canvas_document_camera.dart';
part 'canvas_document_geometry.dart';
part 'canvas_document_queries.dart';
part 'canvas_document_selection.dart';

/// A forged width must not stretch a cull to the whole board.
const double _maxCullPad = 128;

/// The document: index, camera, strokes, and dedupe by id.
class CanvasDocument extends ChangeNotifier {
  CanvasDocument() {
    // A drag that starts and ends between two frames must still invalidate the cached ink.
    elevatedObjectId.addListener(_changed);
  }

  final CanvasScene scene = CanvasScene();

  /// Null past a removal or a clear: the slot address stays reserved
  /// ([UniformGrid] never renumbers) but the stroke itself is freed, which is
  /// the largest memory win available since a `Path` and its points dominate
  /// this package's footprint.
  final List<CanvasStroke?> _strokes = <CanvasStroke?>[];
  final Map<String, int> _slotById = <String, int>{};
  final Map<String, List<int>> _slotsByGroup = <String, List<int>>{};
  final PaintOrderCache _paintOrder = PaintOrderCache();
  final RemovedIds _removed = RemovedIds();

  /// The highest op the owner of this document has applied, or null before it
  /// follows an op stream. A placement at or below it that this document does
  /// not hold was removed since, so it must not come back from a late reply.
  int? reflectedSeq;

  Camera _camera = const Camera();
  Size _viewport = Size.zero;
  double _bottomInset = 0;
  bool _isDisposed = false;
  int _contentRevision = 0;
  double _maxStrokeWidth = 0;
  ui.Rect? _board;
  ui.Rect? _sharedArea;
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

  /// Bumped when an object already placed changes how it paints (a move, a
  /// removal, a reorder, a bitmap); a new object does not, so a cache of the
  /// committed ink can layer additions over itself instead of rebuilding.
  int get contentRevision => _contentRevision;

  /// How far a cull reaches past a box so thick ink at the screen edge still paints.
  double get cullPad => math.min(_maxStrokeWidth / 2, _maxCullPad);

  /// Half the widest pen placed so far, uncapped: how far past its box any ink can reach.
  double get maxInkReach => _maxStrokeWidth / 2;

  void _changed() => _contentRevision++;

  /// Whether [dispose] ran, so a timer that outlives the document can skip it.
  bool get isDisposed => _isDisposed;

  Camera get camera => _camera;

  /// The kind of the latest press, so a finger's reach follows the finger and not the window width.
  PointerDeviceKind lastPointerKind = PointerDeviceKind.mouse;

  /// The lowest zoom a wheel or pinch may aim for: the board's fit when that sits below [minZoom].
  double get zoomFloor {
    final board = _board;
    if (board == null || _viewport.isEmpty) return minZoom;
    return math.min(minZoom, boardFitZoom(board, _fitView));
  }

  Size get viewport => _viewport;

  /// The dock's share of the viewport's foot; see [setBottomInset].
  double get bottomInset => _bottomInset;

  /// The viewport less the floating dock at its foot: what fitting and
  /// clamping the board aim at, while painting and culling still use all of it.
  Size get _fitView => Size(
        _viewport.width,
        math.max(
            math.min(1, _viewport.height), _viewport.height - _bottomInset),
      );

  /// How much of the viewport's foot a floating dock covers, so the fitted
  /// board sits above it and its bottom edge stays reachable.
  void setBottomInset(double inset) {
    final next = inset.isFinite ? math.max(0.0, inset) : 0.0;
    if (next == _bottomInset) return;
    _bottomInset = next;
    final board = _board;
    _camera = board != null && _atFit ? _sharedCamera(board) : _clamp(_camera);
    _reculled();
  }

  /// Slots the last cull kept, in paint order.
  List<int> get paintOrder => _paintOrder.order(
        slotCount: _strokes.length,
        isAlive: (slot) => _strokes[slot]?.alive ?? false,
        compare: comparePaintOrder,
        visible: scene.visible,
      );

  /// Adds a stroke, returns the slot it already occupies, or refuses one this document was told to drop.
  /// Dedupe by id makes every fetch path safe to repeat, and `RemovedIds` stops a read in flight during a removal from resurrecting it.
  /// [overwrite] is for snapshot reads, authoritative for box and text; a live echo or placement reply can arrive after a newer move and never sets it.
  int? applyPlaced(
    CanvasStrokeInput input, {
    bool overwrite = false,
    int? snapshotSeq,
  }) {
    if (_removed.contains(input.id)) {
      if (!_restoredBefore(input.id, snapshotSeq)) return null;
      forgetRemoved([input.id]);
    }
    final known = _slotById[input.id];
    if (!overwrite && known == null && _alreadyReflected(input.seq)) {
      return null;
    }
    if (known != null) {
      return _refreshKnown(known, input, overwrite: overwrite);
    }
    return _addStroke(input);
  }

  int? _refreshKnown(
    int known,
    CanvasStrokeInput input, {
    required bool overwrite,
  }) {
    final existing = _strokes[known];
    // A duplicate naming a slot this document has since freed is refused.
    if (existing == null) return null;
    // A stroke given up as failed whose commit did land comes back.
    if (!existing.alive) {
      existing.alive = true;
      objectCount.value = objectCount.value + 1;
      _trackOutside(existing);
    }
    // A repeated placement reply must not undo a reorder that landed after the original.
    if (overwrite || input.seq == 0 || input.seq > existing.seq) {
      existing
        ..zIndex = input.zIndex
        ..seq = input.seq;
    }
    if (overwrite) _overwriteFrom(existing, input);
    _paintOrder.markDirty();
    _changed();
    return known;
  }

  int _addStroke(CanvasStrokeInput input) {
    final path = smoothPolyline(input.points);
    final points = Float32List(input.points.length);
    for (var i = 0; i + 1 < input.points.length; i += 2) {
      points[i] = input.points[i] + input.x;
      points[i + 1] = input.points[i + 1] + input.y;
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
        groupId: input.groupId,
        flipX: input.flipX,
        flipY: input.flipY,
      ),
    );
    if (input.groupId case final group?) {
      (_slotsByGroup[group] ??= <int>[]).add(slot);
    }
    _slotById[input.id] = slot;
    _maxStrokeWidth = math.max(_maxStrokeWidth, input.width);
    _trackOutside(_strokes[slot]);
    objectCount.value = objectCount.value + 1;
    _paintOrder.markDirty();
    return slot;
  }

  /// Attaches a decoded bitmap to a live image object; [image] is disposed instead if [id] died while the decode ran, since nothing else would free it.
  void setImageBitmap(String id, ui.Image image) {
    final slot = _slotById[id];
    final stroke = slot == null ? null : _strokes[slot];
    if (stroke == null || !stroke.alive) {
      image.dispose();
      return;
    }
    // A tier swap or a repeat paste replaces a held bitmap, which nothing else frees.
    if (!identical(stroke.image, image)) stroke.image?.dispose();
    stroke.image = image;
    stroke.imageLoadFailed = false;
    _changed();
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
    _changed();
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
    _changed();
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
    _releaseSelection(id);
    _trackOutside(stroke);
    objectCount.value = objectCount.value - 1;
    _paintOrder.markDirty();
    _changed();
  }

  /// A dying object must not stay offered a resize, reorder or delete.
  void _releaseSelection(String id) {
    if (selectedObjectId.value == id) selectedObjectId.value = null;
    if (elevatedObjectId.value == id) elevatedObjectId.value = null;
  }

  /// True for an id taken off the board by a removal, as opposed to [kill]'s
  /// never-landed one.
  bool wasRemoved(String id) => _removed.contains(id);

  /// Removes a placed object by id, or records the id as removed even if never held, closing the in-flight-viewport-page race.
  /// A no-op for an id already removed or never placed, so a replayed batch costs nothing.
  void removeObject(String id, {int? seq}) {
    _removed.add(id, seq: seq);
    final slot = _slotById[id];
    if (slot != null) _freeSlot(slot);
  }

  /// Removes every stroke placed at or below [beforeSeq]; the `0 <` guard spares a local stroke (`seq: 0` until confirmed) so a clear in flight does not erase ink as it is drawn.
  /// [kinds] and [authorId] narrow it like a scoped clear, [opSeq] is the clear's own seq when known, and [spare] names locked objects left standing.
  void clearBelow(
    int beforeSeq, {
    Set<CanvasObjectKind> kinds = const {},
    String? authorId,
    int? opSeq,
    Set<String> spare = const {},
  }) {
    for (var slot = 0; slot < _strokes.length; slot++) {
      final stroke = _strokes[slot];
      if (stroke == null || stroke.seq <= 0 || stroke.seq > beforeSeq) continue;
      if (kinds.isNotEmpty && !kinds.contains(stroke.kind)) continue;
      if (authorId != null && stroke.authorId != authorId) continue;
      if (spare.contains(stroke.id)) continue;
      _removed.add(stroke.id, seq: opSeq);
      _freeSlot(slot);
    }
  }

  /// Everyone who authored an object still on the board.
  Set<String> authorIds() => {
        for (final stroke in _strokes)
          if (stroke != null && stroke.alive && stroke.authorId != null)
            stroke.authorId!,
      };

  /// Records that the server numbered the removal of [ids] as [seq].
  void confirmRemoved(Iterable<String> ids, int seq) =>
      _removed.confirm(ids, seq);

  /// Drops ids from the removed-id tombstone set after a restore, so a later fetch can land again.
  /// The stale `_slotById` entry goes too: `applyPlaced` refuses a duplicate naming a freed slot even when the id is no longer tombstoned.
  void forgetRemoved(Iterable<String> ids) {
    final restored = ids.toSet();
    if (restored.isEmpty) return;
    _removed.removeAll(restored);
    // A live or killed stroke keeps its address, or the next read would add a second copy.
    _slotById.removeWhere(
      (id, slot) => restored.contains(id) && _strokes[slot] == null,
    );
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
    _slotsByGroup.clear();
    _paintOrder.clear();
    _removed.clear();
    scene.reset();
    _outsideIds.clear();
    outsideBoardCount.value = 0;
    objectCount.value = 0;
    selectedObjectId.value = null;
    elevatedObjectId.value = null;
    _maxStrokeWidth = 0;
    _changed();
    notifyListeners();
  }

  void _freeSlot(int slot) {
    final stroke = _strokes[slot];
    if (stroke == null) return;
    _releaseSelection(stroke.id);
    scene.remove(slot);
    if (_outsideIds.remove(stroke.id)) {
      outsideBoardCount.value = _outsideIds.length;
    }
    stroke.image?.dispose();
    _strokes[slot] = null;
    // A killed stroke was already counted out.
    if (stroke.alive) objectCount.value = objectCount.value - 1;
    _paintOrder.markDirty();
    _changed();
  }

  void _disposeImages() {
    for (final stroke in _strokes) {
      stroke?.image?.dispose();
    }
  }

  /// Re-culls against the current camera and repaints; separate from [applyPlaced] so a snapshot of hundreds of objects costs one cull and one repaint.
  void refresh() => _reculled();

  void _reculled() {
    final board = _board;
    final view = board == null ? worldView : worldView.intersect(board);
    final pad = cullPad;
    scene.setViewport(
      view.left - pad,
      view.top - pad,
      view.right + pad,
      view.bottom + pad,
    );
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
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
