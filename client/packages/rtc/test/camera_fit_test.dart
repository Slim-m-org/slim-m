// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Each surface picks how a camera feed fills its box: a portrait feed must
/// not be cropped to a strip where the whole picture is the point.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  group('fitShowsWholeFeed', () {
    test('cover never letterboxes and contain always does', () {
      for (final aspect in [0.5625, 1.0, 1.78]) {
        expect(fitShowsWholeFeed(CameraFit.cover, aspect), isFalse);
        expect(fitShowsWholeFeed(CameraFit.contain, aspect), isTrue);
      }
    });

    test('coverUnlessPortrait letterboxes only a feed taller than wide', () {
      expect(fitShowsWholeFeed(CameraFit.coverUnlessPortrait, 9 / 16), isTrue);
      expect(fitShowsWholeFeed(CameraFit.coverUnlessPortrait, 1.0), isFalse);
      expect(fitShowsWholeFeed(CameraFit.coverUnlessPortrait, 16 / 9), isFalse);
    });
  });

  group('CameraFitScope', () {
    Future<CameraFit> read(WidgetTester tester, {CameraFit? fit}) async {
      late CameraFit seen;
      Widget probe = Builder(
        builder: (context) {
          seen = CameraFitScope.of(context);
          return const SizedBox.shrink();
        },
      );
      if (fit != null) probe = CameraFitScope(fit: fit, child: probe);
      await tester.pumpWidget(probe);
      return seen;
    }

    testWidgets('covers when no scope is above', (tester) async {
      expect(await read(tester), CameraFit.cover);
    });

    testWidgets('the nearest scope decides', (tester) async {
      expect(await read(tester, fit: CameraFit.contain), CameraFit.contain);
    });
  });
}
