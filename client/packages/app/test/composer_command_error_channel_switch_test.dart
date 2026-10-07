// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/slash_command.dart';

import 'composer_harness.dart';

void main() {
  testWidgets('a command error banner from c1 is gone after switching to c2', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    final sends = Sends();
    Widget harness(String channelId) => composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.linux,
      channelId: channelId,
      extraOverrides: [
        slashCommandProvider.overrideWith(
          (ref) async => const [
            api.SlashCommand(
              moduleId: 'dice',
              command: 'roll',
              name: 'roll',
              description: 'Roll dice',
            ),
          ],
        ),
      ],
    );

    usePicker(pickedFile());
    await tester.pumpWidget(harness('c1'));
    await tester.pumpAndSettle();
    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '/roll 2d6');
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();
    expect(find.textContaining('cannot carry an attachment'), findsOneWidget);

    controller.clear();
    await tester.pumpWidget(harness('c2'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('cannot carry an attachment'),
      findsNothing,
      reason: "c1's command error must not show in c2",
    );
  });
}
