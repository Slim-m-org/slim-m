// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The mentioner-only bot help card: appears once per bot per message,
/// dismisses, and never repeats noisily. See
/// docs/decisions/0031-bot-command-registration.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';
import 'package:slimm_design_system/design_system.dart';

import 'features/composer/composer_harness.dart';

final _helperCommands = [
  const api.ChannelBotCommand(
    botUserId: 'bot-1',
    botUsername: 'helper',
    botDisplayName: 'Helper',
    prefix: '!',
    name: 'ping',
    description: "check if I'm alive",
  ),
];

Widget _harness(TextEditingController controller, Sends sends) =>
    composerHarness(
      controller: controller,
      sends: sends,
      platform: TargetPlatform.iOS,
      extraOverrides: [
        channelBotCommandsProvider('c1').overrideWith((ref) => _helperCommands),
      ],
    );

void main() {
  late TextEditingController controller;
  late Sends sends;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
    sends = Sends();
  });

  tearDown(() => controller.dispose());

  testWidgets('mentioning a registered bot shows its help card', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(controller, sends));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hey @helper can you');
    await tester.pump();

    expect(find.textContaining('answers to "!"'), findsOneWidget);
    expect(find.textContaining('!ping'), findsOneWidget);
  });

  testWidgets('mentioning a name with nothing registered shows no card', (
    tester,
  ) async {
    await tester.pumpWidget(_harness(controller, sends));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'hey @someone-else');
    await tester.pump();

    expect(find.textContaining('answers to'), findsNothing);
  });

  testWidgets('dismissing the card hides it, and retyping the same mention '
      'does not bring it back', (tester) async {
    await tester.pumpWidget(_harness(controller, sends));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@helper');
    await tester.pump();
    expect(find.textContaining('answers to'), findsOneWidget);

    await tester.tap(find.byIcon(AppIcons.dismiss));
    await tester.pump();
    expect(find.textContaining('answers to'), findsNothing);

    // Delete and retype the exact same mention within the same message.
    await tester.enterText(find.byType(TextField), '@help');
    await tester.pump();
    await tester.enterText(find.byType(TextField), '@helper');
    await tester.pump();

    expect(
      find.textContaining('answers to'),
      findsNothing,
      reason: 'the same mention must not repeat the card in one message',
    );
  });

  testWidgets('sending clears the seen set, so a fresh message can show it '
      'again', (tester) async {
    await tester.pumpWidget(_harness(controller, sends));
    await tester.pump();

    await tester.enterText(find.byType(TextField), '@helper');
    await tester.pump();
    await tester.tap(find.byIcon(AppIcons.dismiss));
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'ping please @helper');
    await tester.pump();
    await tester.tap(sendButton);
    await tester.pump();

    controller.clear();
    await tester.pump();
    await tester.enterText(find.byType(TextField), '@helper');
    await tester.pump();

    expect(find.textContaining('answers to'), findsOneWidget);
  });
}
