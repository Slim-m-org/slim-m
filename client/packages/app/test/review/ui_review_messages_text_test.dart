// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Review captures of `msg-row-text`: the message row's text states in the
/// real transcript, at phone and desktop width in both themes. PNGs are
/// written only under SLIMM_UI_SNAPSHOTS=1; otherwise each case asserts a
/// clean layout.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/emoji/providers/emoji_catalog_provider.dart';
import 'package:slimm_app/src/features/modules/providers/code_block_runner.dart';

import '../ui_snapshot_support.dart';
import 'ui_review_messages_media.dart';
import 'ui_review_messages_support.dart';

const _surface = 'msg-row-text';

const _ada = 'user-ada';
const _nick = 'user-nick';

const _markdown =
    '# Resync notes\n'
    '> the tail replays strictly in order, never by arrival\n'
    '\n'
    '- replay every op after the last seen `seq`\n'
    '- a subscriber that lags past capacity is dropped\n'
    '  - and resyncs over REST\n'
    '\n'
    '1. fetch the tail\n'
    '2. apply it by seq\n'
    '\n'
    'Details are in https://slim.example.org/docs/resync, and the '
    'cause was ||the lock ordering on the hub||. Ship it :partyparrot:';

const _snippet =
    '```python\n'
    'ops = [3, 1, 2]\n'
    'print(sorted(ops))\n'
    '```';

final _run = api.CodeRun(
  blockIndex: 0,
  moduleId: 'code-exec',
  command: 'run',
  ok: true,
  output: '[1, 2, 3]',
  ranBy: _nick,
  ranAt: 1753600000000 + 6 * 60000,
);

List<api.Message> _lead() => [
  reviewMessage(1, _ada, 'morning, did anyone look at the resync path?'),
];

typedef _Case = ({
  List<api.Message> messages,
  List<Override> overrides,
  SceneStep? seed,
});

_Case _plain(List<api.Message> messages) =>
    (messages: messages, overrides: const [], seed: null);

final _cases = <String, _Case>{
  'markdown': (
    messages: [..._lead(), reviewMessage(2, _ada, _markdown)],
    overrides: [
      customEmojiIndexProvider.overrideWithValue(const {
        'partyparrot': 'e-parrot',
      }),
      customEmojiImageProvider('e-parrot').overrideWith(
        (ref) async =>
            landscapePng(64, 64, sky: 0x7fd36b, ground: 0xe8a33d, sun: 0.5),
      ),
    ],
    seed: null,
  ),
  'code-run': (
    messages: [
      ..._lead(),
      reviewMessage(2, _nick, _snippet, codeRuns: [_run]),
    ],
    overrides: [
      codeBlockRunnerProvider.overrideWith(
        (ref) async => const [
          api.CodeBlockRunner(
            moduleId: 'code-exec',
            command: 'run',
            language: 'python',
          ),
        ],
      ),
    ],
    seed: null,
  ),
  'bot-author': _plain([
    ..._lead(),
    reviewMessage(
      2,
      'user-bot',
      'Reminder: the resync review is on **Friday** at 14:00.',
      viaModule: const api.ViaModule(
        id: 'reminders',
        name: 'Reminders',
        background: false,
      ),
    ),
    reviewMessage(3, _ada, 'thanks, adding it to my calendar'),
    reviewMessage(
      4,
      'user-bot',
      'Weekly digest: 12 messages, 3 open threads.',
      viaModule: const api.ViaModule(
        id: 'digest',
        name: 'Digest',
        background: true,
      ),
    ),
  ]),
  'reply-quote': _plain([
    ..._lead(),
    reviewMessage(
      2,
      _nick,
      'yes, it was the seq ordering on resync',
      replyToId: 'r-1',
    ),
  ]),
  'reply-parent-deleted': _plain([
    reviewMessage(
      2,
      _nick,
      'yes, it was the seq ordering on resync',
      replyToId: 'r-gone',
    ),
  ]),
  'own': _plain([
    ..._lead(),
    reviewMessage(
      2,
      _nick,
      'it was the seq ordering - fixed in the hub, tests are green',
      editedAt: 1753600000000 + 3 * 60000,
      reactions: const [
        api.ReactionSummary(emoji: '\u{1F44D}', count: 2, reacted: true),
      ],
    ),
    reviewMessage(3, _nick, 'a follow-up from me, grouped under the first'),
  ]),
  'mention': _plain([
    ..._lead(),
    reviewMessage(
      2,
      _ada,
      '@nick can you review the resync change before Friday?',
      mentionsMe: true,
    ),
  ]),
};

void main() {
  setUpAll(() async {
    await loadRealFonts();
    await loadEmojiFont();
  });

  for (final entry in _cases.entries) {
    for (final viewport in reviewViewports.keys) {
      testWidgets('${entry.key} at $viewport', (tester) async {
        final spec = entry.value;
        await captureMessages(
          tester,
          surface: _surface,
          state: entry.key,
          viewport: viewport,
          messages: spec.messages,
          overrides: spec.overrides,
          seed: spec.seed,
        );
      });
    }
  }

  for (final viewport in reviewViewports.keys) {
    testWidgets('pending at $viewport', (tester) async {
      await captureMessages(
        tester,
        surface: _surface,
        state: 'pending',
        viewport: viewport,
        messages: _lead(),
        seed: (scene) async => (await scene.store).addPending(
          id: 'pending-1',
          channelId: 'c-general',
          authorId: _nick,
          content: 'looks right to me - sending the fix over now',
        ),
      );
    });
  }
}
