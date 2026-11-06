// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where a point on a viewer's tile lands on the shared screen, including past
/// the letterbox bars, and which monitor a share is taken to cover.
library;

import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/screen_overlay/providers/screen_annotation_mapping.dart';
import 'package:slimm_platform/platform.dart';

OverlayMonitor _monitor(int w, int h, {bool primary = false}) =>
    OverlayMonitor(x: 0, y: 0, width: w, height: h, primary: primary);

void main() {
  group('fitContent', () {
    test('a wider screen in a taller tile leaves bars above and below', () {
      final r = fitContent(const Size(400, 400), 16 / 9);
      expect(r.width, 400);
      expect(r.height, closeTo(225, 1e-9));
      expect(r.top, closeTo(87.5, 1e-9));
      expect(r.left, 0);
    });

    test('a narrower screen in a wider tile leaves bars at the sides', () {
      final r = fitContent(const Size(800, 300), 1);
      expect(r.size, const Size(300, 300));
      expect(r.left, 250);
    });

    test('a matching shape fills the tile', () {
      expect(
        fitContent(const Size(320, 180), 16 / 9),
        const Rect.fromLTWH(0, 0, 320, 180),
      );
    });

    test('a missing aspect falls back to the whole tile', () {
      expect(
        fitContent(const Size(10, 10), 0),
        const Rect.fromLTWH(0, 0, 10, 10),
      );
    });
  });

  group('normalising', () {
    const content = Rect.fromLTWH(0, 87.5, 400, 225);

    test('the content corners are 0 and 1', () {
      expect(toNormalised(const Offset(0, 87.5), content), Offset.zero);
      expect(
        toNormalised(const Offset(400, 312.5), content),
        const Offset(1, 1),
      );
    });

    test('the middle of the tile is the middle of the screen', () {
      expect(
        toNormalised(const Offset(200, 200), content),
        const Offset(0.5, 0.5),
      );
    });

    test('a point on the bars sticks to the screen edge', () {
      expect(toNormalised(const Offset(-20, 0), content), Offset.zero);
      expect(toNormalised(const Offset(500, 999), content), const Offset(1, 1));
    });

    test('mapping out and back is the identity', () {
      const n = Offset(0.25, 0.8);
      final back = toNormalised(fromNormalised(n, content), content);
      expect(back.dx, closeTo(n.dx, 1e-9));
      expect(back.dy, closeTo(n.dy, 1e-9));
    });
  });

  group('pickSharedMonitors', () {
    final monitors = [_monitor(1920, 1080), _monitor(2560, 1600)];

    test('the capturer screen number picks its monitor', () {
      expect(pickSharedMonitors(monitors, screenNumber: 2), [1]);
    });

    test('an out-of-range screen number falls back to every monitor', () {
      expect(pickSharedMonitors(monitors, screenNumber: 7), [0, 1]);
    });

    test('with no number the captured shape picks the monitor', () {
      expect(
        pickSharedMonitors(monitors, capturedSize: const Size(1280, 800)),
        [1],
      );
      expect(
        pickSharedMonitors(monitors, capturedSize: const Size(1280, 720)),
        [0],
      );
    });

    test('a size capture scaled down still picks the same monitor', () {
      expect(
        pickSharedMonitors(monitors, capturedSize: const Size(2304, 1440)),
        [1],
      );
    });

    test(
      'identical monitors are all candidates, never the first by default',
      () {
        final twins = [_monitor(1920, 1080), _monitor(1920, 1080)];
        expect(
          pickSharedMonitors(twins, capturedSize: const Size(1920, 1080)),
          [0, 1],
        );
      },
    );

    test('the portal position settles identical monitors', () {
      const twins = [
        OverlayMonitor(x: 0, y: 0, width: 1920, height: 1080, primary: false),
        OverlayMonitor(
          x: 1920,
          y: 0,
          width: 1920,
          height: 1080,
          primary: false,
        ),
      ];
      const size = Size(1920, 1080);
      expect(
        pickSharedMonitors(
          twins,
          capturedSize: size,
          portalOrigin: (x: 1920, y: 0),
        ),
        [1],
      );
      expect(
        pickSharedMonitors(
          twins,
          capturedSize: size,
          portalOrigin: (x: 5, y: 5),
        ),
        [0, 1],
        reason: 'a position no monitor has falls back to the shape match',
      );
    });

    test('with nothing to go on every monitor is covered', () {
      expect(pickSharedMonitors([_monitor(800, 600), _monitor(800, 600)]), [
        0,
        1,
      ]);
    });
  });

  group('sharedAspect', () {
    final monitors = [_monitor(1920, 1080), _monitor(2560, 1600)];

    test('monitors of one shape give it', () {
      expect(sharedAspect(monitors, [0]), closeTo(1920 / 1080, 1e-9));
    });

    test('monitors of different shapes give none', () {
      expect(sharedAspect(monitors, [0, 1]), isNull);
    });
  });

  test('a capturer label gives its screen number', () {
    expect(screenNumberFromLabel('Screen 2'), 2);
    expect(screenNumberFromLabel('screen 10'), 10);
    expect(screenNumberFromLabel('Entire screen'), isNull);
    expect(screenNumberFromLabel('Screen 2 - Firefox'), isNull);
  });
}
