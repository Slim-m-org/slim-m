// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The suggestion list above the composer for each trigger it opens: `@` for
/// members, `:` for emoji (with the Space's own), `/` for module commands and
/// apps, a bot's own prefix, and a trigger that matches nothing. Phone and
/// desktop, dark and light; the PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1.
///
/// There is no `#` channel list in the composer today, so no case stands for it.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/slash_command.dart';
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';
import 'package:slimm_app/src/features/modules/providers/app_launch.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _surface = 'composer-autocomplete';

void _list(String state, String text, {List<Override> overrides = const []}) =>
    reviewCases(
      _surface,
      state: state,
      body: (tester, viewport) => reviewShadowed(
        (themes) => reviewRoute(
          tester,
          surface: _surface,
          state: state,
          viewport: viewport,
          themes: themes,
          overrides: [...composerSeeds(), ...overrides],
          act: (tester, handles) => typeInComposer(tester, text),
        ),
      ),
    );

const _dice = api.ModuleInfo(name: 'Dice', verified: true);
const _weather = api.ModuleInfo(
  name: 'Weather',
  verified: true,
  capabilities: ['net.fetch'],
  networkHosts: ['api.open-meteo.com'],
);
const _reminders = api.ModuleInfo(
  name: 'Reminders',
  verified: false,
  capabilities: ['schedule', 'message.post'],
);

final _moduleOverrides = [
  slashCommandProvider.overrideWith(
    (ref) async => const [
      api.SlashCommand(
        moduleId: 'dice',
        command: 'roll',
        name: 'roll',
        description: 'Roll dice, like /roll 2d6',
        module: _dice,
      ),
      api.SlashCommand(
        moduleId: 'weather',
        command: 'now',
        name: 'weather',
        description: 'Current weather for a city',
        module: _weather,
      ),
      api.SlashCommand(
        moduleId: 'reminders',
        command: 'add',
        name: 'remind',
        description: 'Remind the channel about something',
        module: _reminders,
      ),
    ],
  ),
  appLaunchProvider.overrideWith(
    (ref) async => const [
      api.App(
        moduleId: 'watch',
        command: 'open',
        name: 'watch',
        description: 'Watch a video together',
        module: api.ModuleInfo(name: 'Watch Party', verified: true),
      ),
    ],
  ),
];

const _botRows = [
  api.ChannelBotCommand(
    botUserId: 'bot-dice',
    botUsername: 'dicebot',
    botDisplayName: 'Dice Bot',
    prefix: '!',
    name: 'roll',
    description: 'roll dice, like !roll 2d6',
  ),
  api.ChannelBotCommand(
    botUserId: 'bot-dice',
    botUsername: 'dicebot',
    botDisplayName: 'Dice Bot',
    prefix: '!',
    name: 'remind',
    description: 'set a reminder for this channel',
  ),
];

void main() {
  setUpAll(loadRealFonts);

  _list('members', '@a');
  _list('emoji', ':sm');
  _list('commands', '/', overrides: _moduleOverrides);
  _list(
    'bot-commands',
    '!r',
    overrides: [
      channelBotCommandsProvider.overrideWith(
        (ref, channelId) async => _botRows,
      ),
    ],
  );
  _list('no-match', '@zzz');
}
