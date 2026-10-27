// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the document promises the surface, and what the splitter promises the
/// server. Removal, tombstones, restore and a hard reset are a sibling file,
/// `canvas_document_removal_test.dart`.
library;

import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

CanvasStrokeInput stroke(
  String id, {
  double x = 0,
  double y = 0,
  int zIndex = 0,
  int? seq,
}) =>
    CanvasStrokeInput(
      id: id,
      seq: seq ?? zIndex,
      zIndex: zIndex,
      x: x,
      y: y,
      w: 10,
      h: 10,
      points: const [0, 0, 10, 10],
      width: 3,
      colorKey: 'annotation',
    );

void main() {
  test('authorId threads from the input to the stored stroke', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'a',
        seq: 1,
        zIndex: 1,
        x: 0,
        y: 0,
        w: 10,
        h: 10,
        points: [0, 0, 10, 10],
        width: 3,
        colorKey: 'annotation',
        authorId: 'alice',
      ),
    );
    document.refresh();

    final slot = document.paintOrder.single;
    expect(document.strokeAt(slot).authorId, 'alice');
  });

  test('an unset authorId is null, not a default sentinel', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..refresh();

    expect(document.strokeAt(document.paintOrder.single).authorId, isNull);
  });

  test('a one-point stroke (a tapped dot) is placed as a real object', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.applyPlaced(
      const CanvasStrokeInput(
        id: 'dot',
        seq: 1,
        zIndex: 1,
        x: 5,
        y: 5,
        w: 0,
        h: 0,
        points: [0, 0],
        width: 3,
        colorKey: 'annotation',
      ),
    );
    document.refresh();

    expect(document.objectCount.value, 1);
    final slot = document.paintOrder.single;
    final placed = document.strokeAt(slot);
    expect(placed.points, [5.0, 5.0]);
    expect(placed.w, 0);
    expect(placed.h, 0);
  });

  test('the same id twice is one object', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    final first = document.applyPlaced(stroke('a'));
    final again = document.applyPlaced(stroke('a'));
    document.applyPlaced(stroke('b', x: 20));
    document.refresh();

    expect(again, first);
    expect(document.objectCount.value, 2);
  });

  test('a killed stroke leaves the paint order', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a'))
      ..applyPlaced(stroke('b', x: 20))
      ..refresh();
    expect(document.paintOrder, hasLength(2));

    document
      ..kill('a')
      ..refresh();
    expect(document.paintOrder, hasLength(1));
    expect(document.objectCount.value, 1);
  });

  /// The cull answers in cell order on one branch and slot order on the other
  /// and switches between them on zoom, so painting it raw would re-layer
  /// overlapping ink as somebody zoomed. Paint order is the server's.
  test('paint order follows z-index, not insertion order', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('late', zIndex: 9))
      ..applyPlaced(stroke('early', x: 20, zIndex: 1))
      ..refresh();

    final ids =
        document.paintOrder.map((slot) => document.strokeAt(slot).id).toList();
    expect(ids, ['early', 'late']);
  });

  /// This cannot exercise the actual web defect (dart2js truncating
  /// `1 << 40` to 0): the whole suite runs on the Dart VM, where a 40-bit
  /// shift is exact either way, so a fixed and an unfixed constant read
  /// identically here. What this pins is the invariant that has to hold
  /// regardless of platform or representation: a stroke drawn locally
  /// paints above everything already confirmed while its commit is still
  /// in flight.
  test('a locally drafted stroke paints above already-confirmed ink', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('confirmed', zIndex: 1))
      ..applyPlaced(stroke('local', x: 20, zIndex: provisionalLocalZIndex))
      ..refresh();

    final ids =
        document.paintOrder.map((slot) => document.strokeAt(slot).id).toList();
    expect(ids, ['confirmed', 'local']);
  });

  /// [CanvasDocument.paintOrder] caches its sort and only re-derives it on a
  /// content change, filtering the cache against the cull for everything
  /// else - a pan or zoom must still move objects in and out of it correctly.
  test(
    'paint order follows the camera in and out of view without a fresh place',
    () {
      final document = CanvasDocument()..setViewport(const Size(800, 600));
      document
        ..applyPlaced(stroke('near', zIndex: 1))
        ..applyPlaced(stroke('far', x: 5000, y: 5000, zIndex: 2))
        ..refresh();

      List<String> ids() => document.paintOrder
          .map((slot) => document.strokeAt(slot).id)
          .toList();

      expect(ids(), ['near']);

      document.setCamera(const Camera(x: 4995, y: 4995));
      expect(ids(), ['far']);

      document.setCamera(const Camera());
      expect(ids(), ['near']);
    },
  );

  test('setZIndex moves an object in paint order without a fresh place', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document
      ..applyPlaced(stroke('a', zIndex: 1))
      ..applyPlaced(stroke('b', x: 20, zIndex: 2))
      ..refresh();

    List<String> ids() =>
        document.paintOrder.map((slot) => document.strokeAt(slot).id).toList();
    expect(ids(), ['a', 'b']);

    document
      ..setZIndex('a', 5)
      ..refresh();

    expect(ids(), ['b', 'a']);
  });

  test('the camera is clamped to the bounded world and the zoom range', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(x: 1e12, y: -1e12, zoom: 400));
    expect(document.camera.zoom, maxZoom);
    expect(document.camera.x, lessThanOrEqualTo(worldLimit));
    expect(document.camera.y, -worldLimit);

    document.setCamera(const Camera(zoom: 0.0001));
    expect(document.camera.zoom, minZoom);
  });

  /// The failure this exists to stop is the worst one on the surface: a legal
  /// stroke over the ceiling gets a 400 and ink already on the drawer's own
  /// screen disappears. Budgeted by encoded bytes, so a point count cannot lie.
  test('a long jittery stroke splits into segments under the byte ceiling', () {
    final points = <Offset>[
      for (var i = 0; i < 4000; i++)
        Offset(i * 1.13337 + 0.5551, (i % 97) * 3.99991),
    ];
    final segments = splitStroke(points, maxPropsBytes: 3500);

    expect(segments.length, greaterThan(1));
    for (final segment in segments) {
      expect(jsonEncode(segment.points).length, lessThanOrEqualTo(3500));
      expect(segment.w, lessThanOrEqualTo(maxObjectExtent));
      expect(segment.h, lessThanOrEqualTo(maxObjectExtent));
    }
  });

  /// Tightened deliberately: at the shipped budget a 256-point cap happens to
  /// land near the ceiling, so a point-count implementation passes by luck. A
  /// smaller budget makes the difference between the two rules visible.
  test('the budget is bytes, not a point count', () {
    final points = <Offset>[
      for (var i = 0; i < 3000; i++)
        Offset(i * 1.13337 + 0.5551, (i % 97) * 3.99991),
    ];
    for (final budget in [600, 1200, 2400]) {
      for (final segment in splitStroke(points, maxPropsBytes: budget)) {
        expect(jsonEncode(segment.points).length, lessThanOrEqualTo(budget));
      }
    }
  });

  test('consecutive segments share an endpoint so a split leaves no seam', () {
    final points = <Offset>[for (var i = 0; i < 2000; i++) Offset(i * 2.5, 0)];
    final segments = splitStroke(points, maxPropsBytes: 400);
    expect(segments.length, greaterThan(2));

    for (var i = 1; i < segments.length; i++) {
      final previous = segments[i - 1];
      final current = segments[i];
      final lastX = previous.x + previous.points[previous.points.length - 2];
      final firstX = current.x + current.points[0];
      expect((lastX - firstX).abs(), lessThan(0.02));
    }
  });

  test('a stroke wider than one object is split on extent too', () {
    final points = <Offset>[
      for (var i = 0; i < 400; i++) Offset(i * 100.0, 0),
    ];
    final segments = splitStroke(points);
    expect(segments.length, greaterThan(1));
    for (final segment in segments) {
      expect(segment.w, lessThanOrEqualTo(maxObjectExtent));
    }
  });

  group('liveCountsByKind', () {
    test('an empty document reports zero of both', () {
      final document = CanvasDocument();
      expect(
        document.liveCountsByKind,
        (strokes: 0, images: 0, notes: 0, shapes: 0, texts: 0),
      );
    });

    test('counts strokes and images separately, ignoring dead slots', () {
      final document = CanvasDocument()
        ..applyPlaced(stroke('a'))
        ..applyPlaced(stroke('b'))
        ..applyPlaced(
          const CanvasStrokeInput(
            id: 'c',
            seq: 1,
            zIndex: 1,
            x: 0,
            y: 0,
            w: 10,
            h: 10,
            points: [],
            width: 0,
            colorKey: '',
            kind: CanvasObjectKind.image,
          ),
        );
      document.kill('b');

      expect(
        document.liveCountsByKind,
        (strokes: 1, images: 1, notes: 0, shapes: 0, texts: 0),
      );
    });
  });
}
