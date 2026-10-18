// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The geometry-clamp math decision 0012 names as fully automatable: whether
/// a saved rectangle still lands on an attached display. No window, no
/// platform channel, plain Dart per the record's own rule.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/window_geometry.dart';

const _primary = DisplayArea(x: 0, y: 0, width: 1920, height: 1080);
const _secondPositionedRight = DisplayArea(
  x: 1920,
  y: 0,
  width: 1920,
  height: 1080,
);

WindowGeometry _windowed({required double x, required double y}) =>
    WindowGeometry(
      windowedSize: const WindowSize(width: 1280, height: 720),
      position: WindowRect(x: x, y: y, width: 1280, height: 720),
    );

void main() {
  group('clampToAttachedDisplays', () {
    test('a rectangle inside an attached display is kept unchanged', () {
      final geometry = _windowed(x: 100, y: 100);

      final clamped = clampToAttachedDisplays(geometry, [_primary]);

      expect(clamped, same(geometry));
    });

    test('a rectangle only overlapping a second display is still kept', () {
      final geometry = _windowed(x: 2000, y: 100);

      final clamped = clampToAttachedDisplays(geometry, [
        _primary,
        _secondPositionedRight,
      ]);

      expect(clamped.position, geometry.position);
    });

    test(
      'a rectangle that overlaps no attached display drops its position',
      () {
        // A monitor unplugged since: nothing attached covers that ground.
        final geometry = _windowed(x: 5000, y: 5000);

        final clamped = clampToAttachedDisplays(geometry, [_primary]);

        expect(clamped.position, isNull);
        expect(
          clamped.windowedSize,
          geometry.windowedSize,
          reason: 'size survives even when position does not',
        );
      },
    );

    test('a window capped to a smaller display is moved back onto it', () {
      // 965x717 saved at 122,16, restored on a 150 percent scaled 853x485 screen.
      const scaled = DisplayArea(x: 0, y: 0, width: 853, height: 485);
      final geometry = WindowGeometry(
        windowedSize: const WindowSize(width: 965, height: 717),
        position: const WindowRect(x: 122, y: 16, width: 965, height: 717),
      );

      final clamped = clampToAttachedDisplays(geometry, [scaled]);
      final placed = clamped.position!;

      expect(placed.x + placed.width, lessThanOrEqualTo(scaled.width));
      expect(placed.x, greaterThanOrEqualTo(0));
      expect(placed.y, greaterThanOrEqualTo(0));
    });

    test('a window hanging off the right edge is nudged left', () {
      final clamped = clampToAttachedDisplays(_windowed(x: 1500, y: 100), [
        _primary,
      ]);

      expect(clamped.position!.x, 1920 - 1280);
      expect(clamped.position!.y, 100);
    });

    test('a window straddling two adjacent displays stays where it is', () {
      final geometry = _windowed(x: 1500, y: 100);

      final clamped = clampToAttachedDisplays(geometry, [
        _primary,
        _secondPositionedRight,
      ]);

      expect(clamped, same(geometry));
    });

    test('an empty display list is treated as nothing to validate against', () {
      final geometry = _windowed(x: 100, y: 100);

      final clamped = clampToAttachedDisplays(geometry, const []);

      expect(
        clamped.position,
        isNull,
        reason:
            'a position this call cannot confirm is safe must not be applied',
      );
    });

    test('a geometry with no saved position passes through untouched', () {
      const geometry = WindowGeometry.fallback;

      final clamped = clampToAttachedDisplays(geometry, [_primary]);

      expect(clamped, same(geometry));
    });

    /// A rectangle sitting exactly at a display's own far edge shares no
    /// area with it - `overlaps` must not treat a shared boundary line as
    /// overlap, or a window one pixel off a display would still "fit".
    test(
      'a rectangle exactly abutting a display, not inside it, is dropped',
      () {
        final geometry = _windowed(x: 1920, y: 0);

        final clamped = clampToAttachedDisplays(geometry, [_primary]);

        expect(clamped.position, isNull);
      },
    );
  });

  group('WindowGeometry JSON round trip', () {
    test('a fully windowed geometry survives encode and decode', () {
      final geometry = _windowed(x: 42, y: 7);

      final restored = WindowGeometry.fromJson(geometry.toJson());

      expect(restored.windowedSize, geometry.windowedSize);
      expect(restored.position?.x, geometry.position?.x);
      expect(restored.position?.y, geometry.position?.y);
      expect(restored.runState, geometry.runState);
    });

    test('a maximized geometry keeps its windowed size for later restore', () {
      final geometry = _windowed(
        x: 10,
        y: 10,
      ).copyWith(runState: WindowRunState.maximized);

      final restored = WindowGeometry.fromJson(geometry.toJson());

      expect(restored.runState, WindowRunState.maximized);
      expect(restored.windowedSize, geometry.windowedSize);
    });

    test('an unrecognised run state decodes as windowed, not a crash', () {
      final json = _windowed(x: 0, y: 0).toJson();
      json['runState'] = 'levitating';

      final restored = WindowGeometry.fromJson(json);

      expect(restored.runState, WindowRunState.windowed);
    });

    test('a null position round-trips as null, not a missing key throwing', () {
      const geometry = WindowGeometry.fallback;

      final restored = WindowGeometry.fromJson(geometry.toJson());

      expect(restored.position, isNull);
    });
  });

  group('looksLikeSplashSize', () {
    test('the splash size itself is flagged', () {
      expect(looksLikeSplashSize(kSplashWindowSize), isTrue);
    });

    test(
      'the owner\'s own corrupted sample - 380x508, the splash height plus a '
      'lingering 48px native title bar - is flagged',
      () {
        expect(
          looksLikeSplashSize(const WindowSize(width: 380, height: 508)),
          isTrue,
        );
      },
    );

    test(
      'one pixel taller than the title-bar margin allows is not flagged',
      () {
        expect(
          looksLikeSplashSize(const WindowSize(width: 380, height: 509)),
          isFalse,
          reason: 'both dimensions must be implausibly small, not just width',
        );
      },
    );

    test('an ordinary desktop size is never flagged', () {
      expect(
        looksLikeSplashSize(const WindowSize(width: 1280, height: 720)),
        isFalse,
      );
    });

    test(
      'a narrow but tall window is not flagged - only one axis is small',
      () {
        expect(
          looksLikeSplashSize(const WindowSize(width: 380, height: 1800)),
          isFalse,
        );
      },
    );

    test('a short but wide window is not flagged - only one axis is small', () {
      expect(
        looksLikeSplashSize(const WindowSize(width: 1920, height: 500)),
        isFalse,
      );
    });
  });

  group('healSplashCorruption', () {
    test('a splash-sized geometry heals to the fallback, dropping position '
        'and run state along with the size', () {
      const corrupted = WindowGeometry(
        windowedSize: WindowSize(width: 380, height: 508),
        position: WindowRect(x: 45, y: 45, width: 380, height: 508),
        runState: WindowRunState.maximized,
      );

      final healed = healSplashCorruption(corrupted);

      expect(healed, same(WindowGeometry.fallback));
    });

    test('a legitimate saved geometry is returned unchanged', () {
      const legitimate = WindowGeometry(
        windowedSize: WindowSize(width: 900, height: 600),
        position: WindowRect(x: 20, y: 20, width: 900, height: 600),
      );

      expect(healSplashCorruption(legitimate), same(legitimate));
    });
  });

  group('clampSizeToMinimum', () {
    test('a size below the floor is enlarged to it', () {
      const small = WindowGeometry(
        windowedSize: WindowSize(width: 580, height: 400),
      );
      final clamped = clampSizeToMinimum(small);
      expect(
        clamped.windowedSize.width,
        WindowGeometry.minimumWindowSize.width,
      );
      expect(
        clamped.windowedSize.height,
        WindowGeometry.minimumWindowSize.height,
      );
    });

    test('only the dimension below the floor is raised', () {
      const wideButShort = WindowGeometry(
        windowedSize: WindowSize(width: 1400, height: 400),
      );
      final clamped = clampSizeToMinimum(wideButShort);
      expect(
        clamped.windowedSize.width,
        1400,
        reason: 'already above the floor',
      );
      expect(
        clamped.windowedSize.height,
        WindowGeometry.minimumWindowSize.height,
      );
    });

    test('a size at or above the floor passes through unchanged', () {
      const ok = WindowGeometry(
        windowedSize: WindowSize(width: 1280, height: 720),
      );
      expect(identical(clampSizeToMinimum(ok), ok), isTrue);
    });

    test('position is preserved when the size is clamped', () {
      const small = WindowGeometry(
        windowedSize: WindowSize(width: 500, height: 500),
        position: WindowRect(x: 10, y: 20, width: 500, height: 500),
      );
      final clamped = clampSizeToMinimum(small);
      expect(clamped.position?.x, 10);
      expect(clamped.position?.y, 20);
    });
  });
}
