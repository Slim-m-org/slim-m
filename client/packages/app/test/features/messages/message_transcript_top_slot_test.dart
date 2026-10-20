// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The transcript's top slot must never disappear from the loaded list once
/// history reaches its start - only swap what fills it - or the list's own
/// item count shrinks by exactly one row right where paging always triggers:
/// near the far end of what is loaded, which is where the reader is scrolled
/// the moment that happens.
///
/// A DM (`channelName: null`) used to return no top slot at all there, the
/// one case `_topSlot`'s own doc comment now names. See
/// `channel_history.dart`'s library doc for why the transcript's scrollbar is
/// a position-within-what-is-loaded indicator rather than a full-history
/// proportion in the first place.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'message_row_harness.dart';
import '../../support/fake_sync.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Widget _app(Widget transcript) => ProviderScope(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
  ],
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(body: transcript),
  ),
);

MessageTranscript _transcript({required String? channelName}) =>
    MessageTranscript(
      channelId: 'c1',
      messages: [
        message(id: 'm1', createdAt: 1700000000000, content: 'first'),
        message(id: 'm2', createdAt: 1700000005000, content: 'second'),
      ],
      syncStatus: SyncStatus.live,
      historyKnown: true,
      channelName: channelName,
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

/// The `ListView.builder`'s own configured item count, read off the real
/// widget rather than inferred from what happens to be built - a `Scrollbar`
/// or `ListView` reads exactly this, so it is the number that matters.
int _itemCount(WidgetTester tester) {
  final delegate =
      tester.widget<ListView>(find.byType(ListView)).childrenDelegate
          as SliverChildBuilderDelegate;
  return delegate.childCount!;
}

void main() {
  testWidgets(
    'a named channel at its true start keeps one extra slot for the welcome',
    (tester) async {
      await tester.pumpWidget(_app(_transcript(channelName: 'general')));
      await tester.pumpAndSettle();

      expect(_itemCount(tester), 3);
      expect(find.byType(ChannelStartHeader), findsOneWidget);
      expect(find.text('Welcome to #general'), findsOneWidget);
    },
  );

  testWidgets(
    'a DM at its true start keeps the same extra slot, filled generically '
    'rather than removed',
    (tester) async {
      await tester.pumpWidget(_app(_transcript(channelName: null)));
      await tester.pumpAndSettle();

      expect(
        _itemCount(tester),
        3,
        reason:
            'the top slot must swap what it shows, never disappear - a '
            'vanished slot shrinks the list exactly where a reader paging '
            'through history is scrolled to when it happens',
      );
      expect(
        find.text('This is the start of your conversation.'),
        findsOneWidget,
      );
      // The DM decision this must not reopen: no "Welcome to #" over a person's name.
      expect(find.textContaining('Welcome to #'), findsNothing);
    },
  );
}
