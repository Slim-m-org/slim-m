// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The committed ink, rasterised once into a texture that pans and zooms draw
/// from.
///
/// Impeller keeps no raster cache, so replaying thousands of strokes costs the
/// GPU the same on every frame, even one a remote cursor merely nudged. A
/// texture a little larger than the view turns that into one image draw.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

import 'canvas_document.dart';

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

/// Objects drawn live over the texture before a rebuild is cheaper.
const int _maxLiveExtras = 48;

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
  int _revision = -1;
  String? _elevated;
  List<bool> _members = const [];
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

  /// Whether the texture can stand in for the ink at [camera].
  bool covers(
    Camera camera,
    Size size,
    int revision,
    String? elevated,
    double dpr,
  ) {
    if (_image == null ||
        revision != _revision ||
        elevated != _elevated ||
        dpr != _dpr) {
      return false;
    }
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

  bool holds(int slot) => slot < _members.length && _members[slot];

  /// Slots of [order] the texture lacks, or null when too many to be worth
  /// layering.
  List<int>? extrasOf(List<int> order) {
    final extras = <int>[];
    for (final slot in order) {
      if (holds(slot)) continue;
      if (extras.length >= _maxLiveExtras) return null;
      extras.add(slot);
    }
    return extras;
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
        if (document.strokeAt(slot).id != elevated) slot,
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
    _revision = document.contentRevision;
    _elevated = elevated;
    _members = List<bool>.filled(document.scene.slotCount, false);
    for (final slot in slots) {
      _members[slot] = true;
    }
    return true;
  }

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
    _revision = -1;
    _members = const [];
  }

  void dispose() {
    _settle?.cancel();
    clear();
  }
}
