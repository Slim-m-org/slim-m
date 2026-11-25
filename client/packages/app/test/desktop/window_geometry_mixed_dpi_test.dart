// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Saved window geometry against displays that each carry their own scale.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';

// 150% primary (2880x1620 physical) with a 100% display to its right.
const _scaledPrimary = DisplayArea(
  x: 0,
  y: 0,
  width: 1920,
  height: 1080,
  scaleFactor: 1.5,
);
const _plainSecondary = DisplayArea(x: 2880, y: 0, width: 1920, height: 1080);

WindowGeometry _saved({required double x, required double scale}) =>
    WindowGeometry(
      windowedSize: const WindowSize(width: 1280, height: 720),
      position: WindowRect(
        x: x,
        y: 100,
        width: 1280,
        height: 720,
        scale: scale,
      ),
    );

void main() {
  group('mixed-DPI geometry', () {
    test('a window saved on the 100% display stays on it', () {
      final out = clampToAttachedDisplays(_saved(x: 3000, scale: 1), [
        _scaledPrimary,
        _plainSecondary,
      ]);

      expect(out.position?.x, 3000);
      expect(out.position?.scale, 1);
    });

    test('a window saved on a 150% display is not matched by a 100% one', () {
      const only = DisplayArea(x: 0, y: 0, width: 1920, height: 1080);
      final out = clampToAttachedDisplays(_saved(x: 1300, scale: 1.5), [only]);

      expect(out.position, isNull);
    });

    test('a rect is restated in the units of the display it lands on', () {
      final out = clampToAttachedDisplays(_saved(x: 2400, scale: 1), [
        _scaledPrimary,
      ]);
      final position = out.position!;

      expect(position.scale, 1.5);
      expect(position.x + position.width, lessThanOrEqualTo(1920));
    });

    test('a save with no scale keeps comparing in plain units', () {
      const geometry = WindowGeometry(
        windowedSize: WindowSize(width: 1280, height: 720),
        position: WindowRect(x: 100, y: 100, width: 1280, height: 720),
      );

      expect(clampToAttachedDisplays(geometry, [_scaledPrimary]), geometry);
    });

    test('the scale survives a save and load, and is absent when unset', () {
      final json = const WindowRect(
        x: 1,
        y: 2,
        width: 3,
        height: 4,
        scale: 1.5,
      ).toJson();

      expect(WindowRect.fromJson(json).scale, 1.5);
      expect(
        const WindowRect(x: 1, y: 2, width: 3, height: 4).toJson(),
        isNot(contains('scale')),
      );
    });
  });
}
