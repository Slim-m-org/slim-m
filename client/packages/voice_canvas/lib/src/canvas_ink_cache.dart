// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The committed ink rasterised once into a texture that pans and zooms draw from.
/// Impeller keeps no raster cache, so replaying thousands of strokes costs the GPU the same every frame, even one a remote cursor nudged.
/// A change to a few objects redraws only the boxes they cover, so a save reply, an undo or an erase never replays the whole board.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'canvas_document.dart';
import 'canvas_ink_members.dart';

/// Paints [slots], bottom first, as seen through [camera].
typedef InkSlotsPainter = void Function(
  Canvas canvas,
  Camera camera,
  List<int> slots,
);

/// How much of the view, on each side, the texture reaches past it.
const double _padFraction = 0.25;

/// The largest texture, in pixels, worth holding for the ink.
const int _maxCachePixels = 24 * 1000 * 1000;

/// The zoom ratio range a texture is stretched over before it is rebuilt.
const double _minScale = 0.5;
const double _maxScale = 2;

/// Objects drawn live over the texture at most, and how many wait for a quiet frame to be folded into it.
const int _maxLiveExtras = 48;
const int _foldExtrasAt = 16;

/// Past this many changed objects, or this share of the texture, a whole rebuild is cheaper than a patch.
const int _maxPatchObjects = 64;
const double _maxPatchShare = 0.4;

/// How long the camera must rest before a stretched texture is sharpened.
const Duration _settleDelay = Duration(milliseconds: 140);

class InkLayerCache {
  InkLayerCache({required this.onSettle});

  /// Asked for one more frame once the camera and content rest.
  final VoidCallback onSettle;

  ui.Image? _image;
  Rect _world = Rect.zero;
  Size _logical = Size.zero;
  double _zoom = 1;
  double _dpr = 1;
  Map<int, InkMember> _members = {};
  int _checkedRevision = -1;
  String? _checkedElevated;
  Timer? _settle;

  double _lastZoom = -1;
  int _lastRevision = -1;
  String? _lastElevated;

  bool get hasImage => _image != null;

  /// Whether a texture for a view of [size] stays inside the pixel budget.
  bool fits(Size size, double dpr) =>
      size.width * dpr * size.height * dpr <= _maxCachePixels;

  /// Records this frame's inputs and says what changed since the previous
  /// frame: with the content unchanged a rebuild pays for itself, and with the
  /// zoom unchanged too the camera has come to rest.
  ({bool content, bool camera}) still(
    double zoom,
    int revision,
    String? elevated,
  ) {
    final content = revision == _lastRevision && elevated == _lastElevated;
    final camera = content && zoom == _lastZoom;
    _lastZoom = zoom;
    _lastRevision = revision;
    _lastElevated = elevated;
    return (content: content, camera: camera);
  }

  /// Whether the texture was drawn at this pixel ratio, near this zoom, around this view.
  bool covers(Camera camera, Size size, double dpr) {
    if (_image == null || dpr != _dpr) return false;
    final scale = camera.zoom / _zoom;
    if (scale < _minScale || scale > _maxScale) return false;
    final view = Rect.fromLTWH(
      camera.x,
      camera.y,
      size.width / camera.zoom,
      size.height / camera.zoom,
    );
    return _world.inflate(1e-6).contains(view.topLeft) &&
        _world.inflate(1e-6).contains(view.bottomRight);
  }

  bool isStretched(Camera camera) => (camera.zoom / _zoom - 1).abs() > 1e-3;

  /// Redraws the texture where its objects changed since it was drawn; false when too much changed to patch.
  bool reconcile(
    CanvasDocument document,
    String? elevated,
    InkSlotsPainter paintSlots,
  ) {
    final revision = document.contentRevision;
    if (revision == _checkedRevision && elevated == _checkedElevated) {
      return true;
    }
    final (:stale, :renumbered) =
        changedInkMembers(document, _members, elevated);
    if (renumbered.isNotEmpty) {
      if (inkStackKept(_members, stale)) {
        for (final slot in renumbered) {
          final member = _members[slot]!;
          member
            ..zIndex = member.stroke.zIndex
            ..seq = member.stroke.seq;
        }
      } else {
        stale.addAll(renumbered);
      }
    }
    if (stale.isNotEmpty &&
        !_patch(document, stale, const [], elevated, paintSlots)) {
      return false;
    }
    _checkedRevision = revision;
    _checkedElevated = elevated;
    return true;
  }

  /// Whether enough of the last extras belong in the texture that a quiet frame should fold them in.
  bool get wantsFolding => _cacheableExtras >= _foldExtrasAt;
  int _cacheableExtras = 0;

  /// The visible slots of [order] the texture lacks, to paint live over it.
  /// Null when too many belong in it, or one belongs under something it holds.
  List<int>? extrasOf(
    CanvasDocument document,
    List<int> order,
    String? elevated,
  ) {
    final extras = <int>[];
    var cacheable = 0;
    for (final slot in order) {
      if (_members.containsKey(slot)) {
        if (cacheable > 0) return null;
        continue;
      }
      extras.add(slot);
      if (inkCacheable(document, document.strokeAt(slot), elevated) &&
          ++cacheable > _maxLiveExtras) {
        return null;
      }
    }
    _cacheableExtras = cacheable;
    return extras;
  }

  /// Draws the visible objects that belong in the texture into it; false when too many to patch.
  bool promote(
    CanvasDocument document,
    List<int> order,
    String? elevated,
    InkSlotsPainter paintSlots,
  ) {
    final adds = [
      for (final slot in order)
        if (!_members.containsKey(slot) &&
            inkCacheable(document, document.strokeAt(slot), elevated))
          slot,
    ];
    return adds.isNotEmpty &&
        _patch(document, const [], adds, elevated, paintSlots);
  }

  /// Rasterises the ink around [camera]; false when the view is too big to hold.
  bool build({
    required CanvasDocument document,
    required Camera camera,
    required Size size,
    required double dpr,
    required String? elevated,
    required InkSlotsPainter paintSlots,
  }) {
    var pad = _padFraction;
    Size logicalFor(double p) =>
        Size(size.width * (1 + 2 * p), size.height * (1 + 2 * p));
    double pixelsFor(Size s) => s.width * dpr * s.height * dpr;
    while (pad > 0 && pixelsFor(logicalFor(pad)) > _maxCachePixels) {
      pad -= 0.05;
    }
    pad = math.max(pad, 0);
    final logical = logicalFor(pad);
    if (pixelsFor(logical) > _maxCachePixels) {
      clear();
      return false;
    }
    final world = Rect.fromLTWH(
      camera.x - size.width * pad / camera.zoom,
      camera.y - size.height * pad / camera.zoom,
      logical.width / camera.zoom,
      logical.height / camera.zoom,
    );
    final slots = [
      for (final slot in document.orderedSlotsIn(world))
        if (inkCacheable(document, document.strokeAt(slot), elevated)) slot,
    ];
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(dpr);
    paintSlots(
        canvas, Camera(x: world.left, y: world.top, zoom: camera.zoom), slots);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(
      (logical.width * dpr).ceil(),
      (logical.height * dpr).ceil(),
    );
    picture.dispose();
    _image?.dispose();
    _image = image;
    _world = world;
    _logical = logical;
    _zoom = camera.zoom;
    _dpr = dpr;
    _members = {
      for (final slot in slots) slot: _memberFor(document.strokeAt(slot)),
    };
    _checkedRevision = document.contentRevision;
    _checkedElevated = elevated;
    return true;
  }

  InkMember _memberFor(CanvasStroke stroke) =>
      InkMember(stroke, inkReach(stroke, _zoom));

  /// Clears the boxes [stale] members covered and [adds] will cover, then repaints every member there, bottom first.
  bool _patch(
    CanvasDocument document,
    List<int> stale,
    List<int> adds,
    String? elevated,
    InkSlotsPainter paintSlots,
  ) {
    final image = _image;
    if (image == null || stale.length + adds.length > _maxPatchObjects) {
      return false;
    }
    final next = <int, InkMember?>{
      for (final slot in stale)
        slot: switch (inkSlotStroke(document, slot)) {
          final now? when inkCacheable(document, now, elevated) =>
            _memberFor(now),
          _ => null,
        },
      for (final slot in adds) slot: _memberFor(document.strokeAt(slot)),
    };
    final boxes = [
      for (final box in <Rect>[
        for (final slot in stale) _members[slot]!.bounds,
        for (final member in next.values)
          if (member != null) member.bounds,
      ])
        if (box.overlaps(_world)) box.intersect(_world),
    ];
    final area = boxes.fold<double>(0, (sum, b) => sum + b.width * b.height);
    if (area > _world.width * _world.height * _maxPatchShare) return false;
    next.forEach((slot, member) {
      if (member == null) {
        _members.remove(slot);
      } else {
        _members[slot] = member;
      }
    });
    final camera = Camera(x: _world.left, y: _world.top, zoom: _zoom);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)..scale(_dpr);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(0, 0, image.width / _dpr, image.height / _dpr),
      _copyPaint,
    );
    for (final box in boxes) {
      canvas
        ..save()
        ..clipRect(_onPixels(box), doAntiAlias: false)
        ..drawColor(const Color(0x00000000), BlendMode.clear);
      paintSlots(canvas, camera, [
        for (final slot in document.orderedSlotsIn(box))
          if (_members.containsKey(slot)) slot,
      ]);
      canvas.restore();
    }
    final picture = recorder.endRecording();
    _image = picture.toImageSync(image.width, image.height);
    picture.dispose();
    image.dispose();
    return true;
  }

  /// [world] in the texture's own logical space, widened to whole device pixels so a cleared box leaves no seam.
  Rect _onPixels(Rect world) {
    double snap(double v, {required bool up}) {
      final pixels = v * _zoom * _dpr;
      return (up ? pixels.ceilToDouble() : pixels.floorToDouble()) / _dpr;
    }

    return Rect.fromLTRB(
      snap(world.left - _world.left, up: false),
      snap(world.top - _world.top, up: false),
      snap(world.right - _world.left, up: true),
      snap(world.bottom - _world.top, up: true),
    );
  }

  static final Paint _copyPaint = Paint()..filterQuality = FilterQuality.none;

  /// Draws the texture where the ink sits for [camera].
  void draw(Canvas canvas, Camera camera, Paint paint) {
    final image = _image;
    if (image == null) return;
    final scale = camera.zoom / _zoom;
    var left = (_world.left - camera.x) * camera.zoom;
    var top = (_world.top - camera.y) * camera.zoom;
    if (scale == 1) {
      // Whole device pixels keep a panned texture exactly as sharp as the ink it replaces.
      left = (left * _dpr).round() / _dpr;
      top = (top * _dpr).round() / _dpr;
    }
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(left, top, _logical.width * scale, _logical.height * scale),
      paint,
    );
  }

  /// Asks for one more frame once things rest, so a stretched texture is
  /// sharpened and a frame painted live is replaced by the texture; without it
  /// the engine keeps replaying the live strokes until something else repaints.
  void settleSoon() {
    _settle?.cancel();
    _settle = Timer(_settleDelay, onSettle);
  }

  void clear() {
    _image?.dispose();
    _image = null;
    _members = {};
    _checkedRevision = -1;
  }

  void dispose() {
    _settle?.cancel();
    clear();
  }
}
