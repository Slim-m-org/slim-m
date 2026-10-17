// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A bot's private answer is a row in the transcript: placed by arrival time,
/// never grouped with a stored message, dismissible, and memory-only.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/messages/providers/ephemeral_messages.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/ephemeral_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';
import 'support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

api.MessageEphemeral _frame(String id, int at, String text) =>
    api.MessageEphemeral(
      channelId: 'c1',
      message: api.EphemeralMessage(
        id: id,
        channelId: 'c1',
        authorId: 'bot-1',
        authorDisplayName: 'Helper',
        content: text,
        inReplyToId: 'm1',
        createdAt: at,
      ),
    );

class _Harness {
  _Harness(this.events, this.container);

  final StreamController<api.ServerEvent> events;
  final ProviderContainer container;

  void send(String id, int at, String text) => events.add(_frame(id, at, text));
}

class _Pane extends ConsumerWidget {
  const _Pane(this.messages);

  final List<dynamic> messages;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final answers = ref.watch(channelEphemeralMessagesProvider('c1'));
    return MessageTranscript(
      channelId: 'c1',
      messages: [...messages.cast()],
      privateAnswers: answers,
      onDismissPrivate: (m) =>
          ref.read(ephemeralMessagesProvider.notifier).dismiss('c1', m.id),
      onReportPrivate: (_) {},
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
      actionsFor: (_, _) => noActions,
      onRetry: (_) {},
      onDiscard: (_) {},
      onPickReaction: (_, _) {},
      onReactionTap: (_, _) {},
      onVote: (_, _) {},
      onSubmitEdit: (_, _) {},
      onCancelEdit: () {},
      onJumpToReply: (_) {},
    );
  }
}

Future<_Harness> _pump(WidgetTester tester, List<dynamic> messages) async {
  final events = StreamController<api.ServerEvent>.broadcast();
  addTearDown(events.close);
  final container = ProviderContainer(
    overrides: [
      liveEventsProvider.overrideWithValue(events.stream),
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
    ],
  );
  addTearDown(container.dispose);
  container.read(ephemeralMessagesProvider);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: _Pane(messages)),
      ),
    ),
  );
  return _Harness(events, container);
}

double _top(WidgetTester tester, String text) =>
    tester.getTopLeft(find.text(text)).dy;

void main() {
  testWidgets('a private answer sits among the stored messages by time', (
    tester,
  ) async {
    final h = await _pump(tester, [
      message(id: 'm1', createdAt: 1000, content: 'first'),
      message(id: 'm2', createdAt: 3000, content: 'second'),
    ]);
    h
      ..send('e1', 2000, 'between')
      ..send('e2', 5000, 'after all');
    await tester.pumpAndSettle();

    expect(_top(tester, 'first'), lessThan(_top(tester, 'between')));
    expect(_top(tester, 'between'), lessThan(_top(tester, 'second')));
    expect(_top(tester, 'second'), lessThan(_top(tester, 'after all')));
    expect(find.text(ephemeralNotice), findsNWidgets(2));
  });

  testWidgets('a private answer never joins a stored message group', (
    tester,
  ) async {
    final h = await _pump(tester, [
      message(id: 'm1', authorId: 'bot-1', createdAt: 1000, content: 'a'),
      message(id: 'm2', authorId: 'bot-1', createdAt: 2000, content: 'b'),
    ]);
    h.send('e1', 1500, 'private');
    await tester.pumpAndSettle();

    final rows = tester.widgetList<MessageRow>(find.byType(MessageRow));
    expect(rows.map((r) => r.grouped), [false, false]);
    expect(rows.map((r) => r.groupContinues), [false, false]);
  });

  testWidgets('without a private answer the same author still groups', (
    tester,
  ) async {
    await _pump(tester, [
      message(id: 'm1', authorId: 'bot-1', createdAt: 1000, content: 'a'),
      message(id: 'm2', authorId: 'bot-1', createdAt: 2000, content: 'b'),
    ]);
    final rows = tester.widgetList<MessageRow>(find.byType(MessageRow));
    expect(rows.where((r) => r.grouped), hasLength(1));
  });

  testWidgets('Dismiss removes the row and the state, nothing else', (
    tester,
  ) async {
    final h = await _pump(tester, [
      message(id: 'm1', createdAt: 1000, content: 'first'),
    ]);
    h.send('e1', 2000, 'secret');
    await tester.pumpAndSettle();
    expect(find.text('secret'), findsOneWidget);

    await tester.tap(find.widgetWithText(AppButton, 'Dismiss'));
    await tester.pumpAndSettle();

    expect(find.text('secret'), findsNothing);
    expect(find.text('first'), findsOneWidget);
    expect(h.container.read(channelEphemeralMessagesProvider('c1')), isEmpty);
  });

  testWidgets('it is memory-only: a fresh session starts with none', (
    tester,
  ) async {
    final h = await _pump(tester, const []);
    h.send('e1', 2000, 'secret');
    await tester.pumpAndSettle();
    expect(h.container.read(ephemeralMessagesProvider)['c1'], hasLength(1));

    h.container.invalidate(ephemeralMessagesProvider);
    expect(h.container.read(ephemeralMessagesProvider), isEmpty);
  });

  testWidgets('a screen reader hears the notice and then the content', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final h = await _pump(tester, const []);
    h.send('e1', 2000, 'you have 500 chips');
    await tester.pumpAndSettle();

    final label = tester.getSemantics(find.byType(EphemeralRow)).label;
    expect(label, startsWith(ephemeralNotice));
    expect(label, contains('you have 500 chips'));
    handle.dispose();
  });

  testWidgets('it fits a phone with an embed and a long name', (tester) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final h = await _pump(tester, [
      message(id: 'm1', createdAt: 1000, content: 'first'),
    ]);
    h.events.add(
      api.MessageEphemeral(
        channelId: 'c1',
        message: const api.EphemeralMessage(
          id: 'e1',
          channelId: 'c1',
          authorId: 'bot-1',
          authorDisplayName: 'A bot with a very long display name indeed',
          content: 'Your balance is 500 chips.',
          inReplyToId: 'm1',
          createdAt: 2000,
          embeds: [api.Embed(title: 'Balance', description: 'Updated')],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Balance'), findsOneWidget);
    expect(
      tester.getRect(find.byType(EphemeralRow)).right,
      lessThanOrEqualTo(390),
    );
  });

  testWidgets('a new answer shows at the bottom of a reader at the bottom', (
    tester,
  ) async {
    final h = await _pump(tester, [
      for (var i = 0; i < 40; i++)
        message(id: 'm$i', createdAt: 1000 + i, content: 'line $i'),
    ]);
    h.send('e1', 5000, 'fresh private');
    await tester.pumpAndSettle();
    expect(find.text('fresh private'), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byType(EphemeralRow)).dy,
      lessThanOrEqualTo(tester.view.physicalSize.height),
    );
  });
}
