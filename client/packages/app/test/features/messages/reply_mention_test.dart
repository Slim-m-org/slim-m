// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The reply ping: the banner's "@ On" / "@ Off" switch, the choice riding the
/// send and its retry, and a pinged reply standing out for the person pinged.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_actions.dart';
import 'package:slimm_app/src/features/messages/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/messages/providers/reply_mention_preference.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_callbacks.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_banner.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'a',
  refreshToken: 'r',
  accessExpiresAt: 99999999999999,
);

List<Override> _signedIn() => [
  sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
];

Widget _banner(String authorId, {List<Override> overrides = const []}) =>
    harness(
      SizedBox(
        width: 460,
        child: ReplyBanner(
          message: message(id: 'p', authorId: authorId, content: 'hello'),
          onCancel: () {},
        ),
      ),
      overrides: [..._signedIn(), ...overrides],
    );

class _Rig {
  _Rig() {
    db = SlimmDatabase(NativeDatabase.memory());
    store = MessageStore(db);
    container = ProviderContainer(
      overrides: [
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost'),
            session: api.SessionStore(tokens: _tokens),
            httpClient: MockClient(_answer),
          ),
        ),
      ],
    );
  }

  late final SlimmDatabase db;
  late final MessageStore store;
  late final ProviderContainer container;
  final bodies = <Map<String, dynamic>>[];
  bool failing = true;

  Future<http.Response> _answer(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    bodies.add(body);
    if (failing) return http.Response('{"error":"boom"}', 503);
    return http.Response(
      jsonEncode({
        'id': body['id'],
        'channel_id': 'c1',
        'author_id': 'me',
        'author_display_name': 'Me',
        'seq': 1,
        'content': body['content'],
        'created_at': 0,
        'edited_at': null,
      }),
      200,
      headers: {'content-type': 'application/json'},
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Widget _row({required bool mentionsMe, required String parentAuthor}) =>
    harness(
      MessageRow(
        message: const Message(
          id: 'r1',
          channelId: 'c1',
          authorId: 'author-1',
          authorDisplayName: 'Priya',
          seq: 6,
          content: 'a reply',
          createdAt: 1700000000000,
          editedAt: null,
          pending: false,
          failed: false,
          replyToId: 'p',
        ),
        grouped: false,
        showNewDivider: false,
        knownUsernames: const {},
        actions: noActions,
        editing: false,
        replyTo: message(
          id: 'p',
          authorId: parentAuthor,
          authorDisplayName: 'Me Myself',
        ),
        extras: MessageExtras(mentionsMe: mentionsMe),
        callbacks: MessageRowCallbacks(
          onRetry: noop,
          onDiscard: noop,
          onPickReaction: (_) {},
          onReactionTap: (_) {},
          onVote: (_) {},
          onSubmitEdit: (_) {},
          onCancelEdit: noop,
        ),
      ),
      overrides: _signedIn(),
    );

Color? _fill(WidgetTester tester) =>
    (tester
                .widget<AnimatedContainer>(find.byKey(MessageRow.hoverFillKey))
                .decoration
            as BoxDecoration?)
        ?.color;

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('the banner switch', () {
    testWidgets('starts on and flips off and on', (tester) async {
      await tester.pumpWidget(_banner('ada'));
      expect(find.text('On'), findsOneWidget);
      expect(find.byTooltip('Mention the author'), findsOneWidget);

      await tester.tap(find.byTooltip('Mention the author'));
      await tester.pump();
      expect(find.text('Off'), findsOneWidget);

      await tester.tap(find.byTooltip('Mention the author'));
      await tester.pump();
      expect(find.text('On'), findsOneWidget);
    });

    testWidgets('remembers the last choice for the next reply', (tester) async {
      await tester.pumpWidget(_banner('ada'));
      await tester.tap(find.byTooltip('Mention the author'));
      await tester.pump();

      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(_banner('bob'));
      await tester.pump();
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('reads a stored off choice after a restart', (tester) async {
      SharedPreferences.setMockInitialValues({replyMentionKey: false});
      await tester.pumpWidget(_banner('ada'));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      expect(find.text('Off'), findsOneWidget);
    });

    testWidgets('is hidden when replying to your own message', (tester) async {
      await tester.pumpWidget(_banner('me'));
      expect(find.byTooltip('Mention the author'), findsNothing);
      expect(find.text('On'), findsNothing);
    });
  });

  group('the send', () {
    late _Rig rig;
    setUp(() => rig = _Rig());
    tearDown(() => rig.dispose());

    test('a reply carries the choice and a retry keeps it', () async {
      await sendOptimistically(
        rig.container.read,
        id: 'm1',
        channelId: 'c1',
        authorId: 'me',
        content: 'hi',
        replyToId: 'p',
        mentionReply: false,
      );
      expect(rig.bodies.single['mention_reply'], isFalse);

      rig.failing = false;
      final failed = (await rig.store.failedMessages()).single;
      await retryMessage(rig.container.read, failed);
      expect(rig.bodies.last['mention_reply'], isFalse);
    });

    test('a retry of a default reply still mentions', () async {
      await sendOptimistically(
        rig.container.read,
        id: 'm1',
        channelId: 'c1',
        authorId: 'me',
        content: 'hi',
        replyToId: 'p',
      );
      rig.failing = false;
      await retryMessage(
        rig.container.read,
        (await rig.store.failedMessages()).single,
      );
      expect(rig.bodies.last['mention_reply'], isTrue);
    });

    test('a plain message carries no mention_reply', () async {
      await sendOptimistically(
        rig.container.read,
        id: 'm1',
        channelId: 'c1',
        authorId: 'me',
        content: 'hi',
      );
      expect(rig.bodies.single.containsKey('mention_reply'), isFalse);
    });
  });

  group('a pinged reply', () {
    testWidgets('gets the accent fill and names the author with an @', (
      tester,
    ) async {
      await tester.pumpWidget(_row(mentionsMe: true, parentAuthor: 'me'));
      final tokens = Theme.of(
        tester.element(find.byType(MessageRow)),
      ).extension<AppTokens>()!;
      expect(_fill(tester), tokens.accentSoft);
      expect(find.textContaining('@Me Myself'), findsOneWidget);
    });

    testWidgets('an ordinary reply has neither', (tester) async {
      await tester.pumpWidget(_row(mentionsMe: false, parentAuthor: 'me'));
      expect(_fill(tester), Colors.transparent);
      expect(find.textContaining('@Me Myself'), findsNothing);
    });
  });
}
