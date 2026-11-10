// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The composer bar in the channel shell, one state at a time: what it says
/// while slow mode counts down, the text is over the limit, the member is
/// timed out, a bot is mentioned, a command fails, a draft comes back and the
/// message runs to several lines. Phone and desktop, dark and light; the PNGs
/// are written only under SLIMM_UI_SNAPSHOTS=1.
///
/// There is no read-only composer: a blocked DM swaps the composer for a
/// notice, which `members-and-moderation` captures.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_drafts.dart';
import 'package:slimm_app/src/features/channels/providers/slow_mode_controller.dart';
import 'package:slimm_app/src/features/composer/providers/slash_command.dart';
import 'package:slimm_app/src/features/members/providers/bot_commands.dart';
import 'package:slimm_app/src/providers/providers.dart';

import 'review_support.dart';
import 'ui_review_composer_and_pickers_support.dart';

const _surface = 'composer-bar';

void _bar(
  String state, {
  List<Override> overrides = const [],
  String? text,
  ReviewAct? act,
}) => reviewCases(
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
      act: (tester, handles) async {
        if (text != null) await typeInComposer(tester, text);
        await act?.call(tester, handles);
      },
    ),
  ),
);

String _overLimit() {
  const sentence =
      'The release notes keep growing because every fix wants its own '
      'paragraph. ';
  final buffer = StringBuffer();
  while (buffer.length < api.kMessageMaxChars + 37) {
    buffer.write(sentence);
  }
  return buffer.toString().substring(0, api.kMessageMaxChars + 37);
}

api.Me _timedOutMe() => api.Me(
  id: 'user-nick',
  username: 'nick',
  displayName: 'Nick',
  createdAt: 0,
  permissions: 6,
  timedOutUntil: DateTime.now()
      .add(const Duration(hours: 3))
      .millisecondsSinceEpoch,
  timeoutReason: 'Posting invite links in #design after two warnings.',
);

const _diceBot = [
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
    name: 'coin',
    description: 'flip a coin',
  ),
  api.ChannelBotCommand(
    botUserId: 'bot-dice',
    botUsername: 'dicebot',
    botDisplayName: 'Dice Bot',
    prefix: '!',
    name: 'pick',
    description: 'pick one of several options',
  ),
];

void main() {
  setUpAll(loadRealFonts);

  _bar(
    'slow-mode',
    text: 'Almost done with the release notes',
    overrides: [
      slowModeRemainingSecondsProvider('c-general').overrideWithValue(23),
    ],
  );

  _bar('over-limit', text: _overLimit());

  _bar(
    'timed-out',
    overrides: [meProvider.overrideWith((ref) async => _timedOutMe())],
  );

  _bar(
    'bot-mention-help',
    text: 'hey @dicebot ',
    overrides: [
      channelBotCommandsProvider.overrideWith(
        (ref, channelId) async => _diceBot,
      ),
    ],
  );

  _bar(
    'command-error',
    text: '/roll',
    overrides: [
      slashCommandProvider.overrideWith(
        (ref) async => const [
          api.SlashCommand(
            moduleId: 'dice',
            command: 'roll',
            name: 'roll',
            description: 'Roll dice, like /roll 2d6',
            module: api.ModuleInfo(name: 'Dice', verified: true),
          ),
        ],
      ),
      ReviewServer(
        extra: (request) => request.url.path == '/modules/dice/commands/roll'
            ? Future.value(
                jsonResponse({
                  'ok': false,
                  'error': 'Dice needs a size, like /roll 2d6.',
                }),
              )
            : null,
      ).override,
    ],
    act: (tester, handles) async {
      await tester.tap(find.byTooltip('Send message'));
      await settleRequest(tester);
    },
  );

  _bar(
    'restored-draft',
    overrides: [
      channelDraftsProvider.overrideWith((ref) {
        final drafts = ChannelDraftsController(ref);
        ref.onDispose(drafts.dispose);
        drafts.save(
          'c-general',
          'Can someone confirm the rail rows line up on a 4K display before I merge?',
        );
        return drafts;
      }),
    ],
  );

  _bar(
    'multi-line',
    text:
        'Release notes for 0.128:\n'
        '- composer drafts survive a restart\n'
        '- polls can be ranked-choice\n'
        '- slow mode shows its countdown\n'
        '- a long list now scrolls instead of growing forever',
  );
}
