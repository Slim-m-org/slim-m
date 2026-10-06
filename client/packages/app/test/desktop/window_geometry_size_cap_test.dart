// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A size saved on a bigger monitor must not outgrow the displays attached now.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';

const _only = DisplayArea(x: 0, y: 0, width: 1920, height: 1080);
const _huge = WindowSize(width: 3800, height: 2100);

void main() {
  group('clampToAttachedDisplays size cap', () {
    test('caps a size saved on a 4k monitor when no position was saved', () {
      const saved = WindowGeometry(windowedSize: _huge);
      final out = clampToAttachedDisplays(clampSizeToMinimum(saved), [_only]);
      expect(out.windowedSize.width, lessThanOrEqualTo(_only.width));
      expect(out.windowedSize.height, lessThanOrEqualTo(_only.height));
    });

    test('caps the size even when the saved position still overlaps', () {
      const saved = WindowGeometry(
        windowedSize: _huge,
        position: WindowRect(x: 10, y: 10, width: 3800, height: 2100),
      );
      final out = clampToAttachedDisplays(saved, [_only]);
      expect(out.windowedSize.width, lessThanOrEqualTo(_only.width));
      expect(out.windowedSize.height, lessThanOrEqualTo(_only.height));
      expect(out.position, isNotNull);
    });

    test('caps against the largest attached display, not the first', () {
      const small = DisplayArea(x: 0, y: 0, width: 1280, height: 720);
      const saved = WindowGeometry(windowedSize: _huge);
      final out = clampToAttachedDisplays(saved, [small, _only]);
      expect(out.windowedSize.width, _only.width);
      expect(out.windowedSize.height, _only.height);
    });

    test('never shrinks below the minimum window size', () {
      const tiny = DisplayArea(x: 0, y: 0, width: 800, height: 600);
      const saved = WindowGeometry(windowedSize: _huge);
      final out = clampToAttachedDisplays(saved, [tiny]);
      expect(out.windowedSize.width, WindowGeometry.minimumWindowSize.width);
      expect(out.windowedSize.height, WindowGeometry.minimumWindowSize.height);
    });

    test('leaves the size alone when no display is reported', () {
      const saved = WindowGeometry(windowedSize: _huge);
      final out = clampToAttachedDisplays(saved, const []);
      expect(out.windowedSize.width, _huge.width);
      expect(out.windowedSize.height, _huge.height);
    });
  });
}
