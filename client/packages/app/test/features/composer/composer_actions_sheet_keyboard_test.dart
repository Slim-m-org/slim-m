// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone composer's + sheet hands the keyboard back after an entry that
/// opens a sheet of its own, the way it did before Photo library had to stop
/// the closing sheet from refocusing the field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    controller = TextEditingController();
    sends = Sends();
  });
  tearDown(() => controller.dispose());

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('closing Create a poll gives the keyboard back', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );
    await tester.tap(find.byWidgetPredicate((w) => w is EditableText));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(moreActionsButton);
    await settle(tester);
    await tester.tap(find.text('Create a poll'));
    await settle(tester);
    expect(find.text('Ranked choice'), findsOneWidget);

    await tester.tapAt(const Offset(20, 20));
    await settle(tester);

    expect(tester.testTextInput.isVisible, isTrue);
  });
}
