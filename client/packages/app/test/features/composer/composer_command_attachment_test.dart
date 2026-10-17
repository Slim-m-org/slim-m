// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A `/command` and a staged file are not compatible, and used to fail
/// quietly.
///
/// Neither command send path carries an attachment: `launchApp` takes no
/// attachment argument at all, and the slash-command run posts its output
/// through `onSend(const [])`. Neither cleared the staging list either, so the
/// file just stayed there while the command went out without it, and nothing
/// told anybody. The composer refuses the send now and says why.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/slash_command.dart';

import 'composer_harness.dart';

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  Widget harness() => composerHarness(
    controller: controller,
    sends: sends,
    platform: TargetPlatform.linux,
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

  testWidgets('a command with a file staged is refused, not sent without it', (
    tester,
  ) async {
    usePicker(pickedFile());
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(attachButton);
    await tester.pumpAndSettle();
    expect(find.text('holiday.png'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '/roll 2d6');
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(
      sends.count,
      0,
      reason: 'the command must not post while a file is staged',
    );
    expect(
      find.textContaining('cannot carry an attachment'),
      findsOneWidget,
      reason: 'and the refusal has to be visible, not silent',
    );
    expect(
      find.text('holiday.png'),
      findsOneWidget,
      reason: 'the file stays staged rather than being thrown away',
    );
  });

  testWidgets('an ordinary message with the same file staged still sends', (
    tester,
  ) async {
    usePicker(pickedFile());
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();

    await tester.tap(attachButton);
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'here you go');
    await tester.pumpAndSettle();
    await tester.tap(sendButton);
    await tester.pumpAndSettle();

    expect(sends.count, 1);
    expect(sends.ids, ['a1']);
  });
}
