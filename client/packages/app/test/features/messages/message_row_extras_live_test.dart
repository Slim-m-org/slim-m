// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Proves the claim `message_extras.dart`'s own doc comment makes: "a live
/// update reaching the cache is a live update reaching the screen".
///
/// Every existing test either drives [MessageExtrasController] directly
/// (`message_extras_thread_live_test.dart`) or mounts [MessageRow] with
/// static props (`message_row_thread_test.dart`); neither exercises
/// [MessageRowExtras] itself, the widget whose `ref.watch` is what actually
/// repaints a row when a live frame lands. This mounts the real transcript,
/// pushes a frame through the same `liveEventsProvider` the app uses, and
/// asserts the rendered text changes with no rebuild trigger beyond the
/// event itself.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'message_row_harness.dart';
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

List<Override> _overrides(Stream<ServerEvent> events) => [
  keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
  sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
  mockApiOverride(
    (request) async => http.Response(
      jsonEncode([]),
      200,
      headers: {'content-type': 'application/json'},
    ),
  ),
  syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
  // Overridden past the noop controller's own dead `liveEvents` getter.
  liveEventsProvider.overrideWithValue(events),
];

Widget _app(Widget transcript, Stream<ServerEvent> events) => ProviderScope(
  overrides: _overrides(events),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: transcript),
  ),
);

MessageTranscript _transcript({required List<Message> messages}) =>
    MessageTranscript(
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

void main() {
  testWidgets('a live ThreadUpdated frame reaches the rendered row through '
      'MessageRowExtras, with nobody reloading', (tester) async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    final messages = [message(id: 'm1', content: 'first')];

    await tester.pumpWidget(
      _app(_transcript(messages: messages), events.stream),
    );
    await tester.pumpAndSettle();

    expect(find.byType(MessageRow), findsOneWidget);
    expect(find.text('1 reply'), findsNothing);

    events.add(
      const ThreadUpdated(
        channelId: 'c1',
        parentMessageId: 'm1',
        threadChannelId: 't1',
        replyCount: 1,
        lastReplyAt: 1700000005000,
      ),
    );
    // No pumpAndSettle: `pump(Duration.zero)` alone flushes the stream's own microtask hop.
    await tester.pump(Duration.zero);

    expect(
      find.textContaining('1 reply'),
      findsOneWidget,
      reason:
          'the frame landed in messageExtrasProvider; MessageRowExtras '
          'must have re-watched it to paint the new text',
    );
  });

  testWidgets('a live ReactionsChanged frame reaches the rendered row too', (
    tester,
  ) async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    final messages = [message(id: 'm1', content: 'first')];

    await tester.pumpWidget(
      _app(_transcript(messages: messages), events.stream),
    );
    await tester.pumpAndSettle();

    expect(find.text('1'), findsNothing);

    events.add(
      const ReactionsChanged(
        channelId: 'c1',
        messageId: 'm1',
        reactions: [ReactionTally(emoji: '\u{1F44D}', count: 1)],
      ),
    );
    await tester.pump(Duration.zero);

    expect(find.text('1'), findsOneWidget);
  });
}
