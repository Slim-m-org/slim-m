// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The jump-to-latest affordance was a full-width labelled bar and covered
/// too much of the transcript it exists to reach, reported from a real
/// phone. This measures the shape rather than inspecting the widget tree,
/// since a `Row` full of the right children can still lay out as wide as the
/// bar it replaced.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/jump_to_latest_button.dart';
import 'package:slimm_design_system/design_system.dart';

/// A bound comfortably above the touch-target floor but nowhere near a
/// full-width bar: the previous "Jump to latest" pill ran well past 100px.
const double _sensibleBound = 56;

Widget _harness({required bool visible}) => MediaQuery(
  data: const MediaQueryData(size: Size(390, 844)),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: JumpToLatestButton(visible: visible, onTap: () {}),
    ),
  ),
);

void main() {
  testWidgets('the visible tap target is compact but meets the touch floor', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(visible: true));
    await tester.pumpAndSettle();

    final size = tester.getSize(
      find.byKey(const Key('jump-to-latest-tap-target')),
    );

    expect(
      size.width,
      lessThanOrEqualTo(_sensibleBound),
      reason: 'a phone-width jump control must not read as a wide bar',
    );
    expect(
      size.height,
      lessThanOrEqualTo(_sensibleBound),
      reason: 'a phone-width jump control must not read as a wide bar',
    );
    expect(
      size.width,
      greaterThanOrEqualTo(AppSizes.rowTouch),
      reason: 'compact must not mean under the touch-target minimum',
    );
    expect(
      size.height,
      greaterThanOrEqualTo(AppSizes.rowTouch),
      reason: 'compact must not mean under the touch-target minimum',
    );
  });

  testWidgets('hidden renders nothing', (tester) async {
    await tester.pumpWidget(_harness(visible: false));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('jump-to-latest-tap-target')), findsNothing);
  });
}
