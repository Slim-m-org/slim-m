// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `MemberProfileBotCommands`: renders a bot's prefix and command list,
/// and nothing at all when there is none. See
/// docs/decisions/0031-bot-command-registration.md.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';
import 'package:slimm_app/src/features/members/widgets/member_profile_bot_commands.dart';
import 'package:slimm_design_system/design_system.dart';

Widget _harness(String botId, api.BotCommandRegistration? registration) =>
    ProviderScope(
      overrides: [
        botCommandRegistrationProvider(botId).overrideWith(
          (ref) async =>
              registration ??
              const api.BotCommandRegistration(prefix: null, commands: []),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: MemberProfileBotCommands(botId: botId)),
      ),
    );

void main() {
  testWidgets('a bot with no registration renders nothing', (tester) async {
    await tester.pumpWidget(_harness('bot-1', null));
    await tester.pump();

    expect(find.byType(Text), findsNothing);
  });

  testWidgets('a registered bot lists its prefix and commands', (tester) async {
    await tester.pumpWidget(
      _harness(
        'bot-1',
        const api.BotCommandRegistration(
          prefix: '!',
          commands: [
            api.RegisteredBotCommand(name: 'ping', description: "I'm alive"),
            api.RegisteredBotCommand(name: 'roll', description: 'roll dice'),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(find.textContaining('answers to !'), findsOneWidget);
    expect(find.textContaining('!ping'), findsOneWidget);
    expect(find.textContaining('!roll'), findsOneWidget);
  });

  testWidgets(
    'a command list past the collapsed count folds into a "Show N more" row '
    'rather than running the card out to its full length',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          'bot-1',
          api.BotCommandRegistration(
            prefix: '!',
            commands: [
              for (var i = 0; i < 12; i++)
                api.RegisteredBotCommand(name: 'cmd$i', description: 'd$i'),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Show 9 more'), findsOneWidget);
      expect(find.textContaining('!cmd2'), findsOneWidget);
      expect(find.textContaining('!cmd3'), findsNothing);
      expect(find.textContaining('!cmd11'), findsNothing);
    },
  );

  testWidgets(
    'tapping "Show N more" reveals every command, and "Show less" folds '
    'them back',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          'bot-1',
          api.BotCommandRegistration(
            prefix: '!',
            commands: [
              for (var i = 0; i < 12; i++)
                api.RegisteredBotCommand(name: 'cmd$i', description: 'd$i'),
            ],
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.textContaining('Show 9 more'));
      await tester.pump();

      expect(
        find.textContaining('!cmd11'),
        findsOneWidget,
        reason: 'every command has to stay reachable once expanded',
      );
      expect(find.textContaining('Show less'), findsOneWidget);

      await tester.tap(find.text('Show less'));
      await tester.pump();

      expect(find.textContaining('!cmd11'), findsNothing);
      expect(find.textContaining('Show 9 more'), findsOneWidget);
    },
  );

  testWidgets(
    'a command list at or under the collapsed count carries no toggle at all',
    (tester) async {
      await tester.pumpWidget(
        _harness(
          'bot-1',
          const api.BotCommandRegistration(
            prefix: '!',
            commands: [
              api.RegisteredBotCommand(name: 'ping', description: "I'm alive"),
              api.RegisteredBotCommand(name: 'roll', description: 'roll dice'),
            ],
          ),
        ),
      );
      await tester.pump();

      expect(find.textContaining('Show'), findsNothing);
    },
  );
}
