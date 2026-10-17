// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot answering a command reads as one tight block: no echo of the command
/// above it, no "edited" on a status that edits itself, and button rows that
/// sit close together at the touch and pointer heights of law 2 in
/// docs/design/desktop-vs-mobile.md.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/providers/user_profiles.dart';
import 'package:slimm_app/src/widgets/message_buttons.dart';
import 'package:slimm_app/src/widgets/message_transcript.dart';
import 'package:slimm_app/src/widgets/reply_quote.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart' as h;
import 'support/fake_sync.dart';

const _rows = [
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: 'Pause',
        style: api.ComponentButtonStyle.primary,
        customId: 'p',
      ),
      api.MessageButton(
        label: '-30s',
        style: api.ComponentButtonStyle.secondary,
        customId: 'b',
      ),
      api.MessageButton(
        label: '+30s',
        style: api.ComponentButtonStyle.secondary,
        customId: 'f',
      ),
      api.MessageButton(
        label: 'Stop',
        style: api.ComponentButtonStyle.danger,
        customId: 's',
      ),
    ],
  ),
  api.ComponentRow(
    buttons: [
      api.MessageButton(
        label: '480p',
        style: api.ComponentButtonStyle.secondary,
        customId: 'q1',
      ),
      api.MessageButton(
        label: '720p',
        style: api.ComponentButtonStyle.primary,
        customId: 'q2',
      ),
    ],
  ),
];

class _Extras extends MessageExtrasController {
  _Extras(super.ref) {
    state = {'bot': const MessageExtras(components: _rows)};
  }
  @override
  void applyMessages(Iterable<api.Message> messages) {}
  @override
  void applyMessage(api.Message message) {}
}

api.UserProfile _profile(String id, {required bool bot}) => api.UserProfile(
  id: id,
  username: id,
  displayName: id,
  createdAt: 0,
  roles: const [],
  isBot: bot,
);

Future<void> _pump(
  WidgetTester tester,
  List<Message> messages, {
  required double width,
  bool botAuthor = true,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late BatchProfilesController profiles;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'self',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
        apiProvider.overrideWith((ref) {
          final client = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient(
              (_) async => http.Response(
                jsonEncode([]),
                200,
                headers: {'content-type': 'application/json'},
              ),
            ),
          );
          ref.onDispose(client.close);
          return client;
        }),
        syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
        messageExtrasProvider.overrideWith(_Extras.new),
        batchProfilesControllerProvider.overrideWith((ref) {
          profiles = BatchProfilesController(ref);
          return profiles;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: MessageTranscript(
            channelId: 'c1',
            messages: messages,
            syncStatus: SyncStatus.live,
            historyKnown: true,
            channelName: 'general',
            scrollController: ScrollController(),
            lastReadSeq: 999999,
            selfId: 'self',
            knownUsernames: const {},
            customEmoji: const {},
            history: const ChannelHistory(atStart: true),
            onLoadOlder: () {},
            onRetryOlder: () {},
            actionsFor: (_, _) => h.noActions,
            onRetry: (_) {},
            onDiscard: (_) {},
            onPickReaction: (_, _) {},
            onReactionTap: (_, _) {},
            onVote: (_, _) {},
            onSubmitEdit: (_, _) {},
            onCancelEdit: () {},
            onJumpToReply: (_) {},
          ),
        ),
      ),
    ),
  );
  profiles.state = {
    'nick': _profile('nick', bot: false),
    'bot-user': _profile('bot-user', bot: botAuthor),
    'eve': _profile('eve', bot: false),
  };
  await tester.pump();
}

Message _command() => h.message(
  id: 'cmd',
  authorId: 'nick',
  authorDisplayName: 'nick',
  content: '!watch x',
  createdAt: 1700000000000,
);

Message _reply({
  String parent = 'cmd',
  String author = 'bot-user',
  String id = 'bot',
  int? editedAt = 1700000005000,
}) => Message(
  id: id,
  channelId: 'c1',
  authorId: author,
  authorDisplayName: author,
  seq: 6,
  content: 'X - 0:37 / 1:48:50 - 720p',
  createdAt: 1700000001000,
  editedAt: editedAt,
  replyToId: parent,
  pending: false,
  failed: false,
);

void main() {
  for (final width in [390.0, 1280.0]) {
    group('at $width', () {
      testWidgets('an adjacent bot reply drops the echoed command', (t) async {
        await _pump(t, [_command(), _reply()], width: width);
        expect(find.byType(ReplyQuote), findsNothing);
      });

      testWidgets('a far parent keeps its quote', (t) async {
        final between = h.message(id: 'mid', authorId: 'eve', content: 'hi');
        await _pump(t, [_command(), between, _reply()], width: width);
        expect(find.byType(ReplyQuote), findsOneWidget);
      });

      testWidgets('a human replier keeps the quote', (t) async {
        await _pump(
          t,
          [_command(), _reply(author: 'eve')],
          width: width,
          botAuthor: false,
        );
        expect(find.byType(ReplyQuote), findsOneWidget);
      });

      testWidgets('a bot answering a non-command keeps the quote', (t) async {
        final chat = h.message(id: 'cmd', authorId: 'nick', content: 'hello');
        await _pump(t, [chat, _reply()], width: width);
        expect(find.byType(ReplyQuote), findsOneWidget);
      });

      testWidgets('a bot message carries no edited marker', (t) async {
        await _pump(t, [_command(), _reply()], width: width);
        expect(find.text('edited'), findsNothing);
      });

      testWidgets('a human message keeps its edited marker', (t) async {
        final human = h.message(
          id: 'hm',
          authorId: 'eve',
          content: 'x',
          editedAt: 1700000009000,
        );
        await _pump(t, [human], width: width, botAuthor: false);
        expect(find.text('edited'), findsOneWidget);
      });

      testWidgets('button rows sit at law 2 heights and close together', (
        t,
      ) async {
        await _pump(t, [_command(), _reply()], width: width);
        final touch = width < kCompactWidth;
        final want = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
        final pause = t.getRect(find.text('Pause').first);
        final fortyP = t.getRect(find.text('480p'));
        final buttons = find.byType(AppButton);
        for (var i = 0; i < buttons.evaluate().length; i++) {
          expect(t.getSize(buttons.at(i)).height, want);
        }
        Rect around(String label) => t.getRect(
          find.ancestor(of: find.text(label), matching: find.byType(AppButton)),
        );
        expect(
          around('480p').top -
              [
                'Pause',
                '-30s',
                '+30s',
                'Stop',
              ].map((l) => around(l).bottom).reduce((a, b) => a > b ? a : b),
          lessThanOrEqualTo(AppSpacing.s4),
        );
        expect(pause.top, lessThan(fortyP.top));
        expect(find.byType(MessageButtons), findsOneWidget);
      });
    });
  }
}
