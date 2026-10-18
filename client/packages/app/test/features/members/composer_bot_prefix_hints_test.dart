// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer's command hints follow each bot's real prefix, and two bots
/// answering one trigger never list twice. See
/// docs/decisions/0069-bot-prefix-assignment.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';

import '../composer/composer_harness.dart';

api.ChannelBotCommand _command(String bot, String prefix, String name) =>
    api.ChannelBotCommand(
      botUserId: 'id-$bot',
      botUsername: bot,
      botDisplayName: bot,
      prefix: prefix,
      name: name,
      description: 'does $name',
    );

final _commands = [
  _command('jellyfin', '!', 'watch'),
  _command('deals', '!', 'watch'),
  _command('music', '~', 'play'),
];

void main() {
  late TextEditingController controller;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    controller = TextEditingController();
  });

  tearDown(() => controller.dispose());

  Future<void> type(WidgetTester tester, String text) async {
    await tester.pumpWidget(
      composerHarness(
        controller: controller,
        sends: Sends(),
        platform: TargetPlatform.iOS,
        extraOverrides: [
          channelBotCommandsProvider('c1').overrideWith((ref) => _commands),
        ],
      ),
    );
    await tester.pump();
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  testWidgets('typing slash lists a shared trigger once', (tester) async {
    await type(tester, '/wa');
    expect(find.text('!watch'), findsOneWidget);
  });

  testWidgets('typing a bot prefix lists that bot\'s commands only', (
    tester,
  ) async {
    await type(tester, '~pl');
    expect(find.text('~play'), findsOneWidget);
    expect(find.text('!watch'), findsNothing);
  });

  testWidgets('a prefix no bot registered opens no list', (tester) async {
    await type(tester, '?wa');
    expect(find.text('!watch'), findsNothing);
  });
}
