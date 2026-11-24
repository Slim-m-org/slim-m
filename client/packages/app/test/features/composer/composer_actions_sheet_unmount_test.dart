// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A choice made in the + sheet after its composer left the screen does
/// nothing, instead of running on a composer that is gone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composer_harness.dart';

void main() {
  testWidgets('picking an entry after the composer is gone does nothing', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sends = Sends();
    Widget harness({required bool mounted}) => composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.iOS,
      mountComposer: mounted,
    );
    await tester.pumpWidget(harness(mounted: true));
    await tester.tap(moreActionsButton);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Create a poll'), findsOneWidget);

    await tester.pumpWidget(harness(mounted: false));
    await tester.tap(find.text('Create a poll'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Ranked choice'), findsNothing);
  });
}
