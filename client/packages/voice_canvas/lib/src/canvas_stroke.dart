// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The wire-facing shapes [CanvasDocument] stores: the camera, the input a
/// placement carries, and the stroke ready to paint.
///
/// Split out of `canvas_document.dart`, which was past the 300-line review
/// budget; `canvas_document.dart` re-exports this library, so nothing that
/// imported it for these types has to change.
library;

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

/// What a placed object is. `stroke` is pen ink; `image` is a pasted picture,
/// decoded and painted by the app layer, which is the one place this package
/// steps outside pure geometry; `note` carries typed text inside its own box;
/// `shape` is one of [CanvasShapeKind] drawn from its own box.
enum CanvasObjectKind { stroke, image, note, shape }

/// Which primitive a [CanvasObjectKind.shape] object draws. A line and an
/// arrow are always the diagonal of the object's own box - top-left corner to
/// bottom-right - rather than an independent pair of points, which is what
/// lets [CanvasDocument.moveObject] reshape either one with the exact same
/// box arithmetic a rectangle or an ellipse already uses: resizing the box
/// *is* redrawing the line, with no separate points array to keep in step.
enum CanvasShapeKind { rectangle, ellipse, line, arrow }

/// How many erased ids [CanvasDocument] remembers so an in-flight fetch
/// cannot resurrect one, matching the server's own `MAX_OBJECTS_PER_CHANNEL`:
/// no viewport read in flight can name more live ids than the channel's own
/// ceiling.
const int maxRemovedIdsTracked = 20000;

/// Half-width of the bounded world, matching the server's own `WORLD_LIMIT`.
/// The canvas is large but finite (owner decision 0001) - large enough that
/// a person can genuinely get lost in it, which is what [cameraToFit] and the
/// Recenter action are the way back from.
const double worldLimit = 5000000.0;

/// Longest side one object may declare, matching the server's
/// `MAX_OBJECT_EXTENT`. A stroke is a mark, not a region.
const double maxObjectExtent = 8192.0;

/// The z-index a locally drawn stroke is given before the server's own
/// answer confirms it, so it paints above everything already known while
/// its commit is still in flight.
///
/// Written as a decimal literal rather than `1 << 40`: dart2js's bitwise
/// shift truncates to 32 bits (`JSInt._shlPositive` returns 0 past a shift
/// of 31), so on the web the shift silently evaluated to 0 - at or below
/// every real server z-index, since the first one issued is 1 - and a
/// freshly drawn stroke rendered underneath existing ink instead of above
/// it. A literal this size has no such limit: dart2js represents an
/// integer up to 2^53 as an exact double, and only the shift operators are
/// unsafe, not the value itself.
const int provisionalLocalZIndex = 1099511627776; // 2^40

/// Zoom is clamped rather than free.
///
/// The floor is not a taste call. The Phase 5 server spike measured the
/// R-Tree losing to a plain scan past about four screens of viewport and
/// recommended the client stop asking for a region wider than that, so the
/// floor keeps an ordinary pan read inside the shape the index is good at.
const double minZoom = 0.25;
const double maxZoom = 4.0;

/// Where the viewport sits in the world.
@immutable
class Camera {
  const Camera({this.x = 0, this.y = 0, this.zoom = 1});

  /// World coordinate at the viewport's top-left.
  final double x;
  final double y;
  final double zoom;

  Camera copyWith({double? x, double? y, double? zoom}) =>
      Camera(x: x ?? this.x, y: y ?? this.y, zoom: zoom ?? this.zoom);

  @override
  bool operator ==(Object other) =>
      other is Camera && other.x == x && other.y == y && other.zoom == zoom;

  @override
  int get hashCode => Object.hash(x, y, zoom);
}

/// The [Camera] that brings [bounds] fully into view inside a [viewport]
/// pane, with [padding] world units of breathing room on every side - what
/// "Recenter" fits to instead of resetting to the world origin. Falls back
/// to the origin camera when there is nothing to fit ([bounds] null) or no
/// measured viewport yet, the same "nothing here" case [CanvasPresenceLayout
/// .withMaxRowWidth] already falls back on.
Camera cameraToFit(Rect? bounds, Size viewport, {double padding = 48}) {
  if (bounds == null || viewport.width <= 0 || viewport.height <= 0) {
    return const Camera();
  }
  final paddedWidth = bounds.width + padding * 2;
  final paddedHeight = bounds.height + padding * 2;
  final zoom = math
      .min(viewport.width / paddedWidth, viewport.height / paddedHeight)
      .clamp(minZoom, maxZoom);
  final centerX = bounds.left + bounds.width / 2;
  final centerY = bounds.top + bounds.height / 2;
  return Camera(
    x: centerX - viewport.width / (2 * zoom),
    y: centerY - viewport.height / (2 * zoom),
    zoom: zoom,
  );
}

/// One stroke as the wire describes it, with no JSON and no api types: the
/// app layer maps a `CanvasObject` onto this so the package stays free of
/// `slimm_api`.
@immutable
class CanvasStrokeInput {
  const CanvasStrokeInput({
    required this.id,
    required this.seq,
    required this.zIndex,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.points,
    required this.width,
    required this.colorKey,
    this.authorId,
    this.kind = CanvasObjectKind.stroke,
    this.attachmentId,
    this.text,
    this.shapeKind,
  });

  final String id;
  final int seq;
  final int zIndex;
  final double x;
  final double y;
  final double w;
  final double h;

  /// Flat `[x0,y0,x1,y1,...]`, relative to [x] and [y], in world units. Empty
  /// for an [CanvasObjectKind.image], [CanvasObjectKind.note] or
  /// [CanvasObjectKind.shape]: none of the three has a path, only a box.
  final List<double> points;
  final double width;

  /// A design-token role name. An unrecognised one renders as the default ink
  /// rather than being dropped, because the set is closed and a row is
  /// durable: a client too old to know a colour must still draw the mark.
  /// Meaningless for an image.
  final String colorKey;

  /// Null for a locally drawn stroke still awaiting its first server answer,
  /// or once the author's account has been anonymized. The eraser scopes a
  /// hit test on this, so an anonymized object is nobody's own ink.
  final String? authorId;

  final CanvasObjectKind kind;

  /// The attachment an [CanvasObjectKind.image] names, so the app layer knows
  /// which bytes to fetch and decode. Null for every other kind.
  final String? attachmentId;

  /// A [CanvasObjectKind.note]'s own text, set once at creation. Null for
  /// every other kind. There is no in-place edit on this canvas for any kind
  /// - a stroke's ink cannot be redrawn and an image's bytes cannot be
  /// swapped - so a note follows the same rule: revising the text means
  /// erasing and re-placing, not editing this field after the fact.
  final String? text;

  /// A [CanvasObjectKind.shape]'s own primitive. Null for every other kind.
  final CanvasShapeKind? shapeKind;
}

/// A stroke ready to paint: its [Path] is built once, at insert, in
/// object-local coordinates and reused every frame.
class CanvasStroke {
  CanvasStroke({
    required this.id,
    required this.x,
    required this.y,
    required this.path,
    required this.points,
    required this.width,
    required this.colorKey,
    required this.zIndex,
    required this.seq,
    this.authorId,
    this.kind = CanvasObjectKind.stroke,
    this.w = 0,
    this.h = 0,
    this.attachmentId,
    this.image,
    this.imageLoadFailed = false,
    this.text,
    this.shapeKind,
  });

  final String id;

  /// Where the object sits, and how big it is. Mutable, with [w] and [h]
  /// below, because a drag repositions the object it started on rather than
  /// replacing it: see [CanvasDocument.moveObject], which is called once per
  /// pointer event and must not allocate an object per event.
  double x;
  double y;

  /// The drawn shape. Reassigned on a move, since `dart:ui` has no in-place
  /// translate - one allocation per move rather than the three a replaced
  /// object cost.
  Path path;
  final double width;
  final String colorKey;

  /// See [CanvasStrokeInput.authorId].
  final String? authorId;

  final CanvasObjectKind kind;

  /// The object's own extent, needed to paint an [CanvasObjectKind.image]
  /// (which has no [path] to bound it) and to reposition either kind on a
  /// move. Mutable with [x] and [y], and for the same reason.
  double w;
  double h;

  /// See [CanvasStrokeInput.attachmentId].
  final String? attachmentId;

  /// The decoded bitmap for an [CanvasObjectKind.image], set once the app
  /// layer has fetched and decoded [attachmentId]'s bytes. Null until then,
  /// and always null for a stroke. Owned by this object: disposed when the
  /// slot holding it is freed or the document is reset, never shared across
  /// two placements of the same attachment (see the package's own doc on
  /// what that costs).
  ui.Image? image;

  /// True once the app layer has given up fetching or decoding
  /// [attachmentId]'s bytes for good - a 403, a 404, or bytes that will not
  /// decode. Distinct from [image] being merely null (still in flight, or
  /// evicted from a bounded cache to be re-fetched later): the painter draws
  /// a visible placeholder for this case rather than silence, so a missing
  /// image reads as a stated fact rather than a blank the eye has to guess
  /// at. Reset to false by [CanvasDocument.setImageBitmap], defensively, in
  /// case a future retry path ever sets a real bitmap after a failure.
  bool imageLoadFailed;

  /// See [CanvasStrokeInput.text].
  final String? text;

  /// See [CanvasStrokeInput.shapeKind].
  final CanvasShapeKind? shapeKind;

  /// Every point in absolute world coordinates, for hit testing against a
  /// world-space pointer with no per-call offset arithmetic.
  ///
  /// `Float32List` rather than `List<double>`: a boxed double runs roughly
  /// 16 bytes against 4, a 4x difference at the 20,000-object ceiling, and
  /// hit testing does not need `double` precision at world scale.
  final Float32List points;

  /// Paint order, lowest first. Corrected from the server's answer once a
  /// locally drawn stroke is confirmed.
  int zIndex;

  /// The op that placed this object, `0` until the server confirms it.
  /// [CanvasDocument.clearBelow] spares `0` deliberately, or a clear in
  /// flight erases ink as it is drawn.
  int seq;

  /// False once a commit has failed for good. The painter skips it; the
  /// grid still finds the slot, since [CanvasDocument.kill] means "this
  /// commit never landed" and is a different thing from a real removal.
  bool alive = true;
}
