// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasDocument.worldEdgeHit] and [CanvasPresenceTileOverrides
/// .worldEdgeHit]: the only signal a person gets that a pan or a tile drag
/// stopped at `worldLimit`, not because something broke.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

void main() {
  group('CanvasDocument.worldEdgeHit', () {
    test('stays false for an ordinary camera move well inside the bound', () {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));

      document.setCamera(const Camera(x: 100, y: 100, zoom: 1));

      expect(document.worldEdgeHit.value, isFalse);
    });

    test('flips true the instant a pan is actually clamped', () {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));

      document.setCamera(const Camera(x: worldLimit + 500, y: 0, zoom: 1));

      expect(document.worldEdgeHit.value, isTrue);
    });

    test('flips back false once the camera moves away from the edge', () {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      document.setCamera(const Camera(x: worldLimit + 500, y: 0, zoom: 1));
      expect(document.worldEdgeHit.value, isTrue);

      document.setCamera(const Camera(x: 0, y: 0, zoom: 1));

      expect(document.worldEdgeHit.value, isFalse);
    });

    test('a viewport resize alone never flips it, only setCamera does', () {
      final document = CanvasDocument();
      addTearDown(document.dispose);
      document.setViewport(const Size(1000, 800));
      document.setCamera(const Camera(x: worldLimit + 500, y: 0, zoom: 1));
      expect(document.worldEdgeHit.value, isTrue);

      document.setViewport(const Size(1200, 900));

      expect(
        document.worldEdgeHit.value,
        isTrue,
        reason: 'unrelated to this test - just proving a resize does not '
            'reach into the flag at all, in either direction',
      );
    });
  });

  group('CanvasPresenceTileOverrides.worldEdgeHit', () {
    test('stays false for an ordinary drag well inside the bound', () {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      overrides.setRect('camera:a', const Rect.fromLTWH(500, 500, 220, 160));

      expect(overrides.worldEdgeHit.value, isFalse);
    });

    test('flips true the instant a drag is actually clamped', () {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);

      overrides.setRect(
        'camera:a',
        const Rect.fromLTWH(worldLimit + 500, 0, 220, 160),
      );

      expect(overrides.worldEdgeHit.value, isTrue);
    });

    test('flips back false once the next drag stays inside the bound', () {
      final overrides = CanvasPresenceTileOverrides();
      addTearDown(overrides.dispose);
      overrides.setRect(
        'camera:a',
        const Rect.fromLTWH(worldLimit + 500, 0, 220, 160),
      );
      expect(overrides.worldEdgeHit.value, isTrue);

      overrides.setRect('camera:a', const Rect.fromLTWH(500, 500, 220, 160));

      expect(overrides.worldEdgeHit.value, isFalse);
    });
  });
}
