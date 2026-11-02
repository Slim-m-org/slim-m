// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [CameraFrameScope] answers false until the camera below it has decoded a
/// frame, and false again once that camera is gone.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

Widget _scope(
  List<bool> seen,
  FirstFrameTracker? tracker, {
  bool mounted = true,
}) =>
    Directionality(
      textDirection: TextDirection.ltr,
      child: CameraFrameScope(
        builder: (_, hasFrame) {
          seen.add(hasFrame);
          return mounted
              ? CameraFrameReporter(tracker: tracker, child: const SizedBox())
              : const SizedBox();
        },
      ),
    );

void main() {
  testWidgets('false until the tracker latches, then true', (tester) async {
    final seen = <bool>[];
    final tracker = FirstFrameTracker();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(_scope(seen, tracker));
    await tester.pump();
    expect(seen.last, isFalse);

    tracker.markFirstFrame();
    await tester.pump();
    expect(seen.last, isTrue);
  });

  testWidgets('a tracker that already has a frame reports it on mount', (
    tester,
  ) async {
    final seen = <bool>[];
    final tracker = FirstFrameTracker()..markFirstFrame();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(_scope(seen, tracker));
    await tester.pump();
    expect(seen.last, isTrue);
  });

  testWidgets('a swapped tracker without a frame reads as false again', (
    tester,
  ) async {
    final seen = <bool>[];
    final first = FirstFrameTracker()..markFirstFrame();
    final second = FirstFrameTracker();
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    await tester.pumpWidget(_scope(seen, first));
    await tester.pump();
    expect(seen.last, isTrue);

    await tester.pumpWidget(_scope(seen, second));
    await tester.pump();
    expect(seen.last, isFalse);
  });

  testWidgets('removing the camera reads as false', (tester) async {
    final seen = <bool>[];
    final tracker = FirstFrameTracker()..markFirstFrame();
    addTearDown(tracker.dispose);
    await tester.pumpWidget(_scope(seen, tracker));
    await tester.pump();
    expect(seen.last, isTrue);

    await tester.pumpWidget(_scope(seen, tracker, mounted: false));
    await tester.pump();
    expect(seen.last, isFalse);
  });

  testWidgets('a reporter outside any scope is harmless', (tester) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: CameraFrameReporter(
          tracker: FirstFrameTracker(),
          child: const SizedBox(),
        ),
      ),
    );
    await tester.pump();
  });
}
