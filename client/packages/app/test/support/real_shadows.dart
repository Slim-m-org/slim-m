// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Makes a capture harness's `BoxShadow` render the way a real device does,
/// closing the artifact that has now misled five separate review passes
/// into reading the floating dock's shadow as a hard-edged defect (see
/// the commit that added this file, and the review passes it names).
///
/// **The cause was never the software rasterizer itself** - it was
/// `flutter_test`'s own `AutomatedTestWidgetsFlutterBinding`, which sets
/// `debugDisableShadows = true` for the whole process specifically so
/// golden-file tests are not flaky across platforms (its own doc comment
/// says so, in `flutter_test/lib/src/binding.dart`). `BoxShadow.toPaint()`
/// reads that flag and drops its `MaskFilter.blur` entirely when it is set,
/// painting a flat, opaque, hard-edged rectangle instead - proven directly
/// by sampling a rendered shadow's pixels with the flag on (a razor-sharp
/// step) and off (a genuine gradient), not assumed from the framework's own
/// doc comment alone.
///
/// A capture PNG here is never diffed against a golden and never asserted
/// on pixel-for-pixel - it exists for a person to look at - so the
/// determinism the framework's default protects buys this harness nothing,
/// while the false "hard-edged bug" it produces has cost real reviewer time
/// five times over.
///
/// **Flipping the flag alone does nothing**: a `RenderObject` only repaints
/// when something marks it dirty, so a boundary already painted once under
/// the disabled flag would still hand back that same picture. This is why
/// [withRealShadows] forces [markNeedsPaint] and a real `pump` both around
/// [capture] and again on the way out - proven by probing this exact shape
/// before trusting it, not assumed either.
///
/// The restore has to finish before this function returns, never via
/// `addTearDown`: `TestWidgetsFlutterBinding._verifyInvariants` runs
/// `debugAssertAllPaintingVarsUnset` the instant a test body's `Future`
/// completes, strictly before any `tearDown`/`addTearDown` callback runs,
/// and that check fails the whole test if `debugDisableShadows` is not back
/// to `true`.
library;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// Repaints [boundary] with real shadow blur for the duration of [capture],
/// then repaints it again with the framework's own flag restored before
/// returning. [capture] is where a caller does its actual `toImage()` and
/// file write - typically inside `tester.runAsync`, since rasterising is
/// real engine work the test's fake clock never completes on its own.
Future<void> withRealShadows(
  WidgetTester tester,
  RenderRepaintBoundary boundary,
  Future<void> Function() capture,
) async {
  debugDisableShadows = false;
  boundary.markNeedsPaint();
  await tester.pump();
  await capture();
  debugDisableShadows = true;
  boundary.markNeedsPaint();
  await tester.pump();
}
