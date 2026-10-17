// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CanvasDocument.setCamera] notifies when the camera moved, and only then.
///
/// Every listener on the document rebuilds when it fires, and the presence
/// layer's rebuild is not cheap - it re-derives tile keys, an identity map and
/// the on-canvas rects before it gets to the part that genuinely depends on
/// where the camera is. A pan or a pinch calls `setCamera` once per pointer
/// event, so a notification that carries no change is a whole rebuild of that
/// for nothing.
///
/// The case that produced it in practice is not a duplicate set but a clamped
/// one: `setCamera` stores `_clamp(next)`, so panning further into a world
/// edge, or pinching past a zoom stop, keeps resolving to the camera already
/// held while the gesture continues. `setViewport` directly above it has
/// always had this guard; `setCamera` did not.
///
/// The pairing matters more than either half. A guard that never notified
/// would pass the first test here and freeze the canvas, so the second half
/// asserts the moves that must still get through, including the one-pixel
/// nudge a coarse guard would swallow.
library;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

/// Counts what a real listener would be woken by.
int _countingNotifies(CanvasDocument document, void Function() body) {
  var notifies = 0;
  void listener() => notifies++;
  document.addListener(listener);
  body();
  document.removeListener(listener);
  return notifies;
}

void main() {
  test('setting the camera it already holds notifies nobody', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(x: 100, y: 100, zoom: 2));

    final notifies = _countingNotifies(document, () {
      for (var i = 0; i < 30; i++) {
        document.setCamera(const Camera(x: 100, y: 100, zoom: 2));
      }
    });

    expect(
      notifies,
      0,
      reason: 'thirty identical sets are thirty rebuilds of the same frame',
    );
    expect(
      document.camera,
      const Camera(x: 100, y: 100, zoom: 2),
      reason: 'and the camera is still the one that was set',
    );
  });

  test('panning further into a world edge stops notifying once it is held', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    // Well past the edge, so every step below clamps to the same camera.
    document.setCamera(const Camera(x: -1e12, y: -1e12, zoom: 1));
    final atEdge = document.camera;

    final notifies = _countingNotifies(document, () {
      for (var i = 1; i <= 20; i++) {
        document.setCamera(Camera(x: -1e12 - i, y: -1e12 - i, zoom: 1));
      }
    });

    expect(
      notifies,
      0,
      reason:
          'a gesture held against the edge must not repaint per pointer event',
    );
    expect(document.camera, atEdge);
  });

  test('pinching past a zoom stop stops notifying once it is held', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(zoom: 1e6));
    final atStop = document.camera;
    expect(atStop.zoom, maxZoom, reason: 'the fixture is really at the stop');

    final notifies = _countingNotifies(document, () {
      for (var i = 1; i <= 20; i++) {
        document.setCamera(Camera(zoom: 1e6 + i));
      }
    });

    expect(notifies, 0);
    expect(document.camera.zoom, maxZoom);
  });

  test('a camera that really moves still notifies, once per move', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(x: 100, y: 100, zoom: 1));

    final notifies = _countingNotifies(document, () {
      document.setCamera(const Camera(x: 101, y: 100, zoom: 1));
      document.setCamera(const Camera(x: 101, y: 102, zoom: 1));
      document.setCamera(const Camera(x: 101, y: 102, zoom: 1.5));
    });

    expect(notifies, 3, reason: 'x, then y, then zoom: three real moves');
    expect(document.camera, const Camera(x: 101, y: 102, zoom: 1.5));
  });

  test('a one-pixel pan is a real move and must survive the guard', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(x: 100, y: 100, zoom: 1));

    final notifies = _countingNotifies(document, () {
      document.setCamera(const Camera(x: 100.5, y: 100, zoom: 1));
    });

    expect(
      notifies,
      1,
      reason: 'a guard coarse enough to swallow this would drop slow drags',
    );
  });

  test('the viewport still culls to the camera the guard let through', () {
    final document = CanvasDocument()..setViewport(const Size(800, 600));
    document.setCamera(const Camera(x: 500, y: 400, zoom: 2));

    expect(
      document.worldView,
      const Rect.fromLTWH(500, 400, 800 / 2, 600 / 2),
      reason: 'the scene must be culled to where the camera actually ended up',
    );
  });
}
