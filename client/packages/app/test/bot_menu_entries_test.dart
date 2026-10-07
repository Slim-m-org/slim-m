// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Rows a bot adds to a message's menu: kept under the bot's own name, capped,
/// and reporting their own failure under the message. See
/// docs/decisions/0045-bot-contributed-ui.md.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/bot_ui_uses.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/bot_menu_sections.dart';
import 'package:slimm_app/src/widgets/bot_ui_failure.dart';
import 'package:slimm_app/src/widgets/message_context_menu.dart';
import 'package:slimm_app/src/widgets/message_row.dart';
import 'package:slimm_app/src/widgets/message_row_callbacks.dart';
import 'package:slimm_design_system/design_system.dart';

import 'message_row_harness.dart';

api.ChannelBotUi _bot(String name, List<String> labels) => api.ChannelBotUi(
  botUserId: 'bot-$name',
  botUsername: name.toLowerCase(),
  botDisplayName: name,
  messageMenu: [
    for (final label in labels) api.BotUiEntry(id: label, label: label),
  ],
  callControls: const [],
);

MessageActions _actionsWith(List<BotMenuSection> sections) => MessageActions(
  canReply: false,
  onReply: noop,
  canEdit: false,
  onEdit: noop,
  canDelete: true,
  onDelete: noop,
  canManagePins: false,
  pinned: false,
  onTogglePin: noop,
  canReport: false,
  onReport: noop,
  canBlockAuthor: false,
  onBlockAuthor: noop,
  canOpenThread: false,
  onOpenThread: noop,
  canCopyLink: false,
  onCopyLink: noop,
  canForward: false,
  onForward: noop,
  canSave: false,
  onSave: noop,
  botSections: sections,
);

Widget _row(MessageActions actions) => harness(
  MessageRow(
    message: message(),
    grouped: false,
    showNewDivider: false,
    knownUsernames: const {},
    actions: actions,
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
);

Offset _pressPoint(WidgetTester tester) =>
    tester.getTopLeft(find.byType(MessageContextMenuRegion)) +
    const Offset(30, 30);

void main() {
  group('botMenuSections', () {
    test('keeps at most the cap in all and drops a bot left with none', () {
      final sections = botMenuSections([
        _bot('One', ['a', 'b', 'c', 'd', 'e', 'f']),
        _bot('Two', ['g', 'h', 'i', 'j', 'k']),
        _bot('Three', ['l']),
      ], onUse: (_, _) {});
      final total = sections.fold<int>(0, (n, s) => n + s.entries.length);
      expect(total, kMaxBotMenuEntries);
      expect(sections.map((s) => s.botName), ['One', 'Two']);
    });

    test('a bot with no menu entries adds no section', () {
      final sections = botMenuSections([_bot('Quiet', [])], onUse: (_, _) {});
      expect(sections, isEmpty);
    });
  });

  testWidgets('bot rows sit under the bot name and badge, after the app rows', (
    tester,
  ) async {
    api.BotUiEntry? used;
    final sections = botMenuSections([
      _bot('Helper', ['Translate']),
    ], onUse: (_, entry) => used = entry);
    await tester.pumpWidget(_row(_actionsWith(sections)));
    await tester.tapAt(
      _pressPoint(tester),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    final delete = tester.getTopLeft(find.text('Delete')).dy;
    final header = tester.getTopLeft(find.text('Helper')).dy;
    final translate = tester.getTopLeft(find.text('Translate')).dy;
    expect(header, greaterThan(delete), reason: 'a bot never precedes the app');
    expect(translate, greaterThan(header));
    expect(find.text('BOT'), findsOneWidget);

    await tester.tap(find.text('Translate'));
    await tester.pumpAndSettle();
    expect(used?.id, 'Translate');
    expect(find.text('Translate'), findsNothing, reason: 'the menu closes');
  });

  testWidgets('a long-press reaches the same rows on a phone', (tester) async {
    final sections = botMenuSections([
      _bot('Helper', ['Translate']),
    ], onUse: (_, _) {});
    await tester.pumpWidget(_row(_actionsWith(sections)));
    await tester.longPressAt(_pressPoint(tester));
    await tester.pumpAndSettle();
    expect(find.text('Translate'), findsOneWidget);
  });

  testWidgets('no bot section appears when no bot offers one', (tester) async {
    await tester.pumpWidget(_row(_actionsWith(const [])));
    await tester.tapAt(
      _pressPoint(tester),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(find.text('BOT'), findsNothing);
  });

  group('using an entry', () {
    Future<
      ({ProviderContainer container, StreamController<api.ServerEvent> events})
    >
    pump(WidgetTester tester, List<Map<String, dynamic>> requests) async {
      final events = StreamController<api.ServerEvent>.broadcast();
      addTearDown(events.close);
      final container = ProviderContainer(
        overrides: [
          liveEventsProvider.overrideWithValue(events.stream),
          apiProvider.overrideWith((ref) {
            final client = api.SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: api.SessionStore(
                tokens: const api.TokenPair(
                  userId: 'u1',
                  accessToken: 'a',
                  refreshToken: 'r',
                  accessExpiresAt: 4102444800000,
                ),
              ),
              httpClient: MockClient((request) async {
                requests.add(jsonDecode(request.body) as Map<String, dynamic>);
                return http.Response(
                  jsonEncode({'id': requests.last['id'], 'created_at': 1}),
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
            ref.onDispose(client.close);
            return client;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(botUiUsesProvider);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildTheme(Brightness.light, AppTokens.light),
            home: const Scaffold(body: BotUiFailureLine(messageId: 'm1')),
          ),
        ),
      );
      return (container: container, events: events);
    }

    testWidgets('sends the target and clears when the bot answers', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final h = await pump(tester, requests);
      unawaited(
        h.container
            .read(botUiUsesProvider.notifier)
            .useMenuEntry(
              channelId: 'c1',
              botId: 'b1',
              entryId: 'translate',
              messageId: 'm1',
            ),
      );
      await tester.pump();
      expect(requests.single['surface'], 'message_menu');
      expect(requests.single['entry_id'], 'translate');
      expect(requests.single['message_id'], 'm1');

      h.events.add(
        api.InteractionAnswered(
          interactionId: requests.single['id'] as String,
          channelId: 'c1',
          messageId: 'm1',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(h.container.read(botUiUsesProvider), isEmpty);
      expect(find.byType(AppErrorState), findsNothing);
    });

    testWidgets('silence puts a persistent error under the message', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final h = await pump(tester, requests);
      unawaited(
        h.container
            .read(botUiUsesProvider.notifier)
            .useMenuEntry(
              channelId: 'c1',
              botId: 'b1',
              entryId: 'translate',
              messageId: 'm1',
            ),
      );
      await tester.pump();
      await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('did not answer'), findsOneWidget);

      await tester.tap(find.text('Retry'));
      await tester.pump();
      expect(requests.length, 2);
      expect(requests.first['id'], isNot(requests.last['id']));
      await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
    });

    testWidgets('a failure shows only under the message it was for', (
      tester,
    ) async {
      final requests = <Map<String, dynamic>>[];
      final h = await pump(tester, requests);
      unawaited(
        h.container
            .read(botUiUsesProvider.notifier)
            .useMenuEntry(
              channelId: 'c1',
              botId: 'b1',
              entryId: 'translate',
              messageId: 'other',
            ),
      );
      await tester.pump();
      await tester.pump(botUiUseTimeout + const Duration(seconds: 1));
      expect(find.byType(AppErrorState), findsNothing);
    });
  });
}
