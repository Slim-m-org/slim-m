// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own character limit: a live counter as the limit
/// approaches, and a refusal to send once it is crossed.
///
/// Closes the reported gap directly, ahead of the server ever being asked:
/// composing well past 4000 characters used to give no warning at all until
/// the send failed, silently and repeatably. This drives the real
/// `Composer` widget rather than the pure helper functions alone, since the
/// bug was that nothing on screen said anything, not that the arithmetic was
/// wrong.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets('well under the limit, no counter appears at all', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.enterText(find.byType(TextField), 'hello there');
    await tester.pump();

    expect(find.textContaining(' / 4000'), findsNothing);
  });

  testWidgets('a live counter appears as the limit is approached', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.enterText(find.byType(TextField), 'a' * 3600);
    await tester.pump();

    expect(find.text('3600 / 4000'), findsOneWidget);
    expect(
      tester.widget<AppIconButton>(sendButton).onPressed,
      isNotNull,
      reason: 'still under the limit, so nothing here should block sending',
    );
  });

  testWidgets('sending is refused once the content is over the limit', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.enterText(find.byType(TextField), 'a' * 4005);
    await tester.pump();

    expect(
      tester.widget<AppIconButton>(sendButton).onPressed,
      isNull,
      reason:
          'a doomed send must never reach the wire once the client already '
          'knows the server would refuse it',
    );
    expect(
      find.textContaining('5 characters over the 4000-character limit'),
      findsOneWidget,
    );
    expect(sends.count, 0);
  });

  testWidgets('trimming back under the limit clears the refusal', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
      ),
    );

    await tester.enterText(find.byType(TextField), 'a' * 4005);
    await tester.pump();
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'a' * 10);
    await tester.pump();

    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);
    expect(find.textContaining('character limit'), findsNothing);
  });
}
