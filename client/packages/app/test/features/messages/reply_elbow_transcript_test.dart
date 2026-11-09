// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A reply in a real transcript: it never groups under the previous message,
/// its connector survives the continuation rail, and a thread draws it the
/// same way a channel does.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/features/messages/widgets/continuation_marker.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row_identity.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_elbow.dart';
import 'package:slimm_app/src/features/messages/widgets/reply_quote.dart';
import 'package:slimm_app/src/features/settings/providers/display_density.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import 'message_row_harness.dart' as h;
import '../../support/fake_sync.dart';
import '../../support/fake_api.dart';

const _base = 1700000000000;

Message _msg(String id, int n, String author, {String? replyTo}) => Message(
  id: id,
  channelId: 'c1',
  authorId: author,
  authorDisplayName: author,
  seq: n,
  content: 'body $id',
  createdAt: _base + n * 1000,
  replyToId: replyTo,
  pending: false,
  failed: false,
);

Future<void> _pump(
  WidgetTester tester,
  List<Message> messages, {
  double width = 390,
  ContinuationMarker marker = ContinuationMarker.none,
  bool thread = false,
}) async {
  SharedPreferences.setMockInitialValues({});
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        SessionStore(
          tokens: const TokenPair(
            userId: 'self',
            accessToken: 'access',
            refreshToken: 'refresh',
            accessExpiresAt: 0,
          ),
        ),
      ),
      mockApiOverride(
        (_) async => http.Response(
          jsonEncode([]),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
    ],
  );
  addTearDown(container.dispose);
  container.read(continuationMarkerControllerProvider.notifier).select(marker);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: MessageTranscript(
            channelId: 'c1',
            messages: messages,
            syncStatus: SyncStatus.live,
            historyKnown: true,
            channelName: 'general',
            channelIsThread: thread,
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
  await tester.pump();
  await tester.pump();
}

Finder _in(String id, Finder matching) =>
    find.descendant(of: find.byKey(ValueKey(id)), matching: matching);

MessageRow _row(WidgetTester t, String id) =>
    t.widget<MessageRow>(_in(id, find.byType(MessageRow)));

Rect _avatar(WidgetTester t, String id) => t.getRect(
  _in(
    id,
    find.descendant(
      of: find.byType(MessageRowLeading),
      matching: find.byType(AppAvatar),
    ),
  ),
);

List<Message> _burst() => [
  _msg('m1', 1, 'ada'),
  _msg('m2', 2, 'ada', replyTo: 'm1'),
  _msg('m3', 3, 'ada'),
];

void main() {
  for (final width in [390.0, 1280.0]) {
    group('at ${width.toInt()} wide', () {
      testWidgets('a reply never groups under the previous message', (
        tester,
      ) async {
        await _pump(tester, _burst(), width: width);
        expect(_row(tester, 'm1').grouped, isFalse);
        expect(_row(tester, 'm2').grouped, isFalse);
        expect(
          _row(tester, 'm3').grouped,
          isTrue,
          reason: 'a plain follow-up still tucks under the reply above it',
        );
        expect(_in('m2', find.byType(MessageRowHeader)), findsOneWidget);
        expect(_in('m2', find.byType(MessageRowLeading)), findsOneWidget);
        expect(_in('m3', find.byType(MessageRowHeader)), findsNothing);
      });

      testWidgets('the quote and its connector sit on top of the reply', (
        tester,
      ) async {
        await _pump(tester, _burst(), width: width);
        final quote = tester.getRect(_in('m2', find.byType(ReplyQuote)));
        final header = tester.getRect(_in('m2', find.byType(MessageRowHeader)));
        final elbow = tester.getRect(_in('m2', find.byKey(ReplyElbow.lineKey)));
        final avatar = _avatar(tester, 'm2');
        expect(quote.bottom, lessThanOrEqualTo(header.top));
        expect(elbow.bottom, avatar.top);
        expect(elbow.left, avatar.left);
        expect(_in('m1', find.byType(ReplyQuote)), findsNothing);
        expect(_in('m3', find.byType(ReplyQuote)), findsNothing);
      });

      testWidgets('the continuation pipe still leaves the reply\'s avatar', (
        tester,
      ) async {
        await _pump(
          tester,
          _burst(),
          width: width,
          marker: ContinuationMarker.clean,
        );
        final pipe = tester.getRect(
          _in('m2', find.byKey(ContinuationHeadRail.railKey)),
        );
        final avatar = _avatar(tester, 'm2');
        expect(pipe.center.dx, closeTo(avatar.center.dx, 0.01));
        expect(pipe.top, avatar.bottom + ContinuationRail.headGap);
        expect(
          pipe.bottom,
          tester.getRect(_in('m2', find.byType(MessageRow))).bottom,
        );
      });

      testWidgets('a thread draws its replies the same way', (tester) async {
        await _pump(
          tester,
          [
            _msg('t1', 1, 'ada'),
            _msg('t2', 2, 'ada', replyTo: 't1'),
            _msg('t3', 3, 'bob', replyTo: 'root-in-the-parent-channel'),
          ],
          width: width,
          thread: true,
        );
        expect(_row(tester, 't2').grouped, isFalse);
        for (final id in ['t2', 't3']) {
          final quote = tester.getRect(_in(id, find.byType(ReplyQuote)));
          final header = tester.getRect(_in(id, find.byType(MessageRowHeader)));
          final elbow = tester.getRect(_in(id, find.byKey(ReplyElbow.lineKey)));
          expect(quote.bottom, lessThanOrEqualTo(header.top), reason: id);
          expect(elbow.bottom, _avatar(tester, id).top, reason: id);
        }
        expect(
          _in('t3', find.text('Message unavailable')),
          findsOneWidget,
          reason: 'the thread root lives in the parent channel',
        );
      });
    });
  }
}
