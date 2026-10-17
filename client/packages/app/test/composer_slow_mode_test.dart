// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's own slow-mode countdown: a band naming the wait, and a
/// disabled send button while it is running - so a member learns about slow
/// mode before typing and tapping, rather than from a 429 after.
///
/// Drives `slowModeRemainingSecondsProvider` directly rather than the
/// channel row and permission bitmask it is composed from
/// (`slow_mode_controller.dart`'s own unit test covers that arithmetic): this
/// suite is only about what `Composer` does with whatever number the
/// provider answers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/providers/slow_mode_controller.dart';
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

  testWidgets('a running countdown shows the wait and disables send', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        extraOverrides: [
          slowModeRemainingSecondsProvider.overrideWith((ref, channelId) => 4),
        ],
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(find.textContaining('Slow mode'), findsOneWidget);
    expect(find.textContaining('4s'), findsOneWidget);
    expect(
      tester.widget<AppIconButton>(sendButton).onPressed,
      isNull,
      reason: 'slow mode must soft-block send, not merely warn about it',
    );
    expect(sends.count, 0);
  });

  testWidgets('zero remaining shows no band and allows sending', (
    tester,
  ) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: sends,
        platform: TargetPlatform.iOS,
        extraOverrides: [
          slowModeRemainingSecondsProvider.overrideWith((ref, channelId) => 0),
        ],
      ),
    );
    await tester.enterText(find.byType(TextField), 'hello');
    await tester.pump();

    expect(find.textContaining('Slow mode'), findsNothing);
    expect(tester.widget<AppIconButton>(sendButton).onPressed, isNotNull);

    await tester.tap(sendButton);
    await tester.pump();
    expect(sends.count, 1);
  });
}
