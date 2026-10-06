// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `BlockedDmNotice`, and the state screen-inventory-moderation.md ranks
/// among the hardest to reach for a screenshot: being blocked *by* the other
/// side of a DM, which carries no client-side signal at all - the block
/// check only ever reads this account's own list, so the composer renders
/// normally and a send simply fails server-side, indistinguishable from any
/// other failed send.
///
/// Two frames stand in for that pair, since the state itself has nothing to
/// screenshot beyond an ordinary composer and an ordinary failed-send row:
/// the filename is the caption, since `ui_capture_html.py`'s contact sheet
/// has no separate caption field.
///
/// Split from `ui_overlay_snapshot_moderation_test.dart` to keep both under
/// this repo's line budget. One viewport (desktop).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/typing_controller.dart';
import 'package:slimm_app/src/widgets/blocked_dm_notice.dart';
import 'package:slimm_app/src/widgets/composer.dart';
import 'package:slimm_app/src/widgets/composer_clipboard_image.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';

import 'message_row_harness.dart' show harness, message, noActions;
import 'support/mid_flight_capture.dart';
import 'ui_snapshot_support.dart';

const _viewport = Size(1400, 880);

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

class _NoopTyping extends StateNotifier<Set<String>>
    implements TypingController {
  _NoopTyping() : super(const {});

  @override
  void notifyTyping() {}
}

class _FixedBlocks extends BlocksController {
  _FixedBlocks(super.ref, BlocksState fixed) {
    state = fixed;
  }

  @override
  Future<void> refresh() async {}
}

Future<void> _finish(
  WidgetTester tester,
  String name, {
  bool allowNoText = false,
}) async {
  await expectSettled(tester, name, allowNoText: allowNoText);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('the notice that replaces the composer when you blocked them', (
    tester,
  ) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        RepaintBoundary(
          key: snapshotBoundary,
          child: const BlockedDmNotice(userId: 'user-maya', name: 'Maya'),
        ),
        overrides: [
          blocksProvider.overrideWith(
            (ref) => _FixedBlocks(
              ref,
              const BlocksState(ids: {'user-maya'}, settled: true),
            ),
          ),
        ],
      ),
    );
    await tester.pump();
    await _finish(tester, 'dm-blocked-by-me-notice-desktop');
  });

  testWidgets('unblocking fails, and the notice stays mounted to say so '
      'inline', (tester) async {
    tester.view.physicalSize = _viewport;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      harness(
        RepaintBoundary(
          key: snapshotBoundary,
          child: const BlockedDmNotice(userId: 'user-maya', name: 'Maya'),
        ),
        overrides: [
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient(
                (request) async => http.Response('{"error":"gone"}', 503),
              ),
            );
            ref.onDispose(client.close);
            return client;
          }),
          blocksProvider.overrideWith(
            (ref) => _FixedBlocks(
              ref,
              const BlocksState(ids: {'user-maya'}, settled: true),
            ),
          ),
        ],
      ),
    );
    await tester.tap(find.text('Unblock Maya'));
    await tester.pumpAndSettle();
    await _finish(tester, 'dm-blocked-by-me-notice-error-desktop');
  });

  group('the invisible half: blocked by the other side', () {
    testWidgets(
      'a composer that looks entirely ordinary - the other side blocked you '
      'and nothing here can tell',
      (tester) async {
        tester.view.physicalSize = _viewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        final controller = TextEditingController(text: 'hey, you around?');
        addTearDown(controller.dispose);

        await tester.pumpWidget(
          harness(
            RepaintBoundary(
              key: snapshotBoundary,
              child: Scaffold(
                body: Column(
                  children: [
                    const Spacer(),
                    Composer(
                      controller: controller,
                      channelId: 'dm-1',
                      channelName: 'maya',
                      onSend: (_) async {},
                      clipboardPasteStart: startClipboardImagePaste,
                      clipboardPasteStop: stopClipboardImagePaste,
                    ),
                  ],
                ),
              ),
            ),
            overrides: [
              typingControllerProvider.overrideWith(
                (ref, channelId) => _NoopTyping(),
              ),
              sessionProvider.overrideWithValue(
                api.SessionStore(tokens: _tokens),
              ),
              apiProvider.overrideWith(
                (ref) => api.SlimmApi(
                  baseUrl: Uri.parse('http://localhost:8080'),
                  session: ref.watch(sessionProvider),
                  httpClient: MockClient(
                    (request) async => http.Response('{}', 404),
                  ),
                ),
              ),
            ],
          ),
        );
        await tester.pump();
        // Deliberately text-free: the whole point is a blocked-by-them composer that looks entirely ordinary, so nothing on it can tell.
        await _finish(
          tester,
          'dm-blocked-by-them-invisible-composer-normal-desktop',
          allowNoText: true,
        );
      },
    );

    testWidgets(
      'the send this composer just made, failed with no mention of why - '
      'the server refused it the moment either side blocked the other, and '
      'this row is byte-for-byte what any other failed send looks like',
      (tester) async {
        tester.view.physicalSize = _viewport;
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          harness(
            RepaintBoundary(
              key: snapshotBoundary,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: MessageRow(
                    message: message(
                      content: 'hey, you around?',
                      failed: true,
                      failureReason: 'Could not send that message.',
                    ),
                    grouped: false,
                    showNewDivider: false,
                    knownUsernames: const {},
                    actions: noActions,
                    editing: false,
                    callbacks: MessageRowCallbacks(
                      onRetry: () {},
                      onDiscard: () {},
                      onPickReaction: (_) {},
                      onReactionTap: (_) {},
                      onVote: (_) {},
                      onSubmitEdit: (_) {},
                      onCancelEdit: () {},
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump();
        await _finish(
          tester,
          'dm-blocked-by-them-invisible-failed-send-desktop',
        );
      },
    );
  });
}
