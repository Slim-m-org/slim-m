// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The pure geometry in `canvas_resize.dart`: which corner a pointer grabs,
/// how a drag reshapes the box, and the two ceilings it must respect.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

const _box = (x: 100.0, y: 100.0, w: 40.0, h: 20.0);

void main() {
  group('hitTestResizeHandle', () {
    test('finds each corner within the screen-space radius', () {
      expect(
        hitTestResizeHandle(_box, const Offset(100, 100), 1),
        ResizeCorner.topLeft,
      );
      expect(
        hitTestResizeHandle(_box, const Offset(140, 100), 1),
        ResizeCorner.topRight,
      );
      expect(
        hitTestResizeHandle(_box, const Offset(100, 120), 1),
        ResizeCorner.bottomLeft,
      );
      expect(
        hitTestResizeHandle(_box, const Offset(140, 120), 1),
        ResizeCorner.bottomRight,
      );
    });

    test('misses the middle of an edge', () {
      expect(hitTestResizeHandle(_box, const Offset(120, 100), 1), isNull);
    });

    /// canvas.md: a 28px-diameter default hit circle is well under this
    /// product's own 44-48dp touch-target floor, and a caller on a touch
    /// surface has to be able to widen it.
    test('an explicit hitRadius widens what a corner catches', () {
      const justOutsideDefault = Offset(100 + resizeHandleHitRadius + 1, 100);
      expect(
        hitTestResizeHandle(_box, justOutsideDefault, 1),
        isNull,
        reason: 'the default radius must not already reach this far',
      );
      expect(
        hitTestResizeHandle(
          _box,
          justOutsideDefault,
          1,
          hitRadius: touchResizeHandleHitRadius,
        ),
        ResizeCorner.topLeft,
        reason: 'the touch radius must reach further than the default one',
      );
    });

    test(
      'the world-space radius shrinks as zoom grows, so a handle never '
      'balloons zoomed in',
      () {
        // At zoom 1 the hit radius is resizeHandleHitRadius world units.
        const justOutsideAtZoom1 = Offset(
          100 + resizeHandleHitRadius + 1,
          100,
        );
        expect(
          hitTestResizeHandle(_box, justOutsideAtZoom1, 1),
          isNull,
          reason: 'a point just past the zoom-1 radius must miss',
        );
        // Zoomed in 10x, the same point still misses the shrunken radius.
        expect(hitTestResizeHandle(_box, justOutsideAtZoom1, 10), isNull);
      },
    );

    test(
      'the world-space radius grows as zoom shrinks, so a handle never '
      'becomes unhittable zoomed out',
      () {
        // Zoomed out 10x, the same screen radius covers 10x the world space.
        const farInWorldSpace = Offset(
          100 - resizeHandleHitRadius * 5,
          100,
        );
        expect(
          hitTestResizeHandle(_box, farInWorldSpace, 0.1),
          ResizeCorner.topLeft,
        );
      },
    );
  });

  group('resizeBounds', () {
    test('the opposite corner from the one grabbed stays fixed', () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        pointerWorld: const Offset(160, 140),
        lockAspect: false,
      );
      expect(result.x, 100, reason: 'top-left (the anchor) must not move');
      expect(result.y, 100);
      expect(result.w, 60);
      expect(result.h, 40);
    });

    test('dragging a corner past the opposite one flips the box', () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        pointerWorld: const Offset(80, 100),
        lockAspect: false,
      );
      // The anchor (top-left, 100,100) is now the box's right edge.
      expect(result.x, 80);
      expect(result.w, 20);
    });

    test('a drag past the floor is clamped rather than collapsing to zero', () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        pointerWorld: const Offset(100.001, 100.001),
        lockAspect: false,
      );
      expect(result.w, minObjectSize);
      expect(result.h, minObjectSize);
    });

    test('a drag past the ceiling stops growing exactly at it', () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        pointerWorld: const Offset(1000000, 1000000),
        lockAspect: false,
      );
      expect(result.w, maxObjectExtent);
      expect(result.h, maxObjectExtent);
    });

    test('locking aspect preserves the original ratio under a free drag', () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        // Free-form this is 60x140; locked, both scale by the larger factor.
        pointerWorld: const Offset(160, 240),
        lockAspect: true,
      );
      expect(result.w, closeTo(_box.w * 7, 0.001));
      expect(result.h, closeTo(_box.h * 7, 0.001));
    });

    test('an aspect-locked drag past the ceiling clamps both sides together',
        () {
      final result = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: _box,
        pointerWorld: const Offset(1000000, 1000000),
        lockAspect: true,
      );
      expect(result.w, lessThanOrEqualTo(maxObjectExtent));
      expect(result.h, lessThanOrEqualTo(maxObjectExtent));
      expect(
        result.w / result.h,
        closeTo(_box.w / _box.h, 0.001),
        reason: 'the ratio must survive being clamped to the ceiling',
      );
    });
  });

  group('resizeBounds inside a board', () {
    const original = (x: 100.0, y: 100.0, w: 100.0, h: 50.0);
    const board = Rect.fromLTWH(0, 0, 400, 300);

    test('an aspect-locked drag stops at the edge with its anchor held', () {
      final box = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: original,
        pointerWorld: const Offset(380, 290),
        lockAspect: true,
        within: board,
      );

      expect(box.x, 100);
      expect(box.y, 100);
      expect(box.x + box.w, lessThanOrEqualTo(400));
      expect(box.y + box.h, lessThanOrEqualTo(300));
      expect(box.w / box.h, closeTo(2, 1e-9));
    });

    test('a free drag stops at the edge on each axis alone', () {
      final box = resizeBounds(
        corner: ResizeCorner.bottomRight,
        original: original,
        pointerWorld: const Offset(900, 250),
        lockAspect: false,
        within: board,
      );

      expect(box.w, 300);
      expect(box.h, 150);
    });
  });
}
