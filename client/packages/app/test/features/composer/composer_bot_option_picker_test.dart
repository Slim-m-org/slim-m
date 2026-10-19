// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot command option with fixed choices is picked from a list under the
/// composer: keyboard navigable, filtered as you type.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/widgets/composer_autocomplete.dart';
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';

import 'composer_harness.dart';

const _sources = ['steam', 'gog', 'epic', 'humble', 'itch', 'ubisoft'];

const _commands = [
  api.ChannelBotCommand(
    botUserId: 'id-deals',
    botUsername: 'deals',
    botDisplayName: 'Deals',
    prefix: '!',
    name: 'sources',
    description: 'pick a store',
    options: [api.BotCommandOption(name: 'source', choices: _sources)],
  ),
];

Finder _listed(String text) => find.descendant(
  of: find.byType(ComposerAutocomplete),
  matching: find.text(text),
);

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
        platform: TargetPlatform.linux,
        extraOverrides: [
          channelBotCommandsProvider('c1').overrideWith((ref) => _commands),
        ],
      ),
    );
    await tester.pump();
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), text);
    await tester.pump();
  }

  testWidgets('a space after the command lists its choices', (tester) async {
    await type(tester, '!sources ');
    for (final choice in _sources) {
      expect(_listed(choice), findsOneWidget);
    }
  });

  testWidgets('typing filters the list', (tester) async {
    await type(tester, '!sources ub');
    expect(_listed('ubisoft'), findsOneWidget);
    expect(_listed('steam'), findsNothing);
  });

  testWidgets('arrow keys move and Enter picks', (tester) async {
    await type(tester, '!sources ');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(controller.text, '!sources epic ');
    expect(find.byType(ComposerAutocomplete), findsOneWidget);
    expect(_listed('epic'), findsNothing);
  });

  testWidgets('a tap picks the choice', (tester) async {
    await type(tester, '!sources go');
    await tester.tap(_listed('gog'));
    await tester.pump();
    expect(controller.text, '!sources gog ');
  });
}
