// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The empty-transcript start header used to float at the top of a mostly
/// empty screen, disconnected from the composer below it: the empty branch
/// of `MessageTranscript.build` used a plain top-anchored
/// `SingleChildScrollView` while every other branch bottom-anchors with a
/// reversed `ListView`.
///
/// Measured geometrically, per this project's own precedent
/// (`message_row_hover_stability_test.dart`), rather than by asserting on the
/// widget tree: either scroll view satisfies a structural "the header is
/// there" check, and only the rendered position tells the two apart.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/messages/widgets/message_row.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';
import '../../support/fake_sync.dart';

const _composerKey = Key('composer');

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

List<Override> _overrides() => [
  keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
  sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
  apiProvider.overrideWith((ref) {
    final api = SlimmApi(
      baseUrl: Uri.parse('http://localhost:8080'),
      session: ref.watch(sessionProvider),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode([]),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    ref.onDispose(api.close);
    return api;
  }),
  syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
];

Widget _app(Widget transcript) => ProviderScope(
  overrides: _overrides(),
  child: MaterialApp(
    theme: buildTheme(Brightness.light, AppTokens.light),
    home: Scaffold(
      body: Column(
        children: [
          Expanded(child: transcript),
          Container(key: _composerKey, height: 56),
        ],
      ),
    ),
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

/// The distance between whatever is rendered lowest on screen (the start
/// header on an empty channel, the newest message on a populated one) and
/// the composer that follows the transcript. Small and constant is the
/// bottom-anchored shape every branch of this widget shares; large is the
/// header floating at the top of an otherwise-empty pane.
double _gapAboveComposer(WidgetTester tester) {
  var lowest = 0.0;
  for (final finder in [
    find.byType(ChannelStartHeader),
    find.byType(MessageRow),
  ]) {
    for (var i = 0; i < finder.evaluate().length; i++) {
      final bottom = tester.getRect(finder.at(i)).bottom;
      if (bottom > lowest) lowest = bottom;
    }
  }
  final composerTop = tester.getRect(find.byKey(_composerKey)).top;
  return composerTop - lowest;
}

void main() {
  testWidgets(
    'an empty channel welcomes above the composer, not at the top of the pane',
    (tester) async {
      // Tall relative to the header, so a top-anchored render leaves the large gap the bug reported.
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_app(_transcript(messages: const [])));
      await tester.pumpAndSettle();

      expect(find.byType(ChannelStartHeader), findsOneWidget);
      expect(
        _gapAboveComposer(tester),
        lessThan(20),
        reason:
            'the welcome header must sit directly above the composer, not '
            'float at the top of the pane with the whole body empty below it',
      );
    },
  );

  testWidgets(
    'a short channel keeps bottom-anchoring after the empty-case fix',
    (tester) async {
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final messages = [
        message(id: 'm1', createdAt: 1700000000000, content: 'first'),
        message(id: 'm2', createdAt: 1700000005000, content: 'second'),
      ];
      await tester.pumpWidget(_app(_transcript(messages: messages)));
      await tester.pumpAndSettle();

      expect(find.byType(ChannelStartHeader), findsOneWidget);
      expect(find.byType(MessageRow), findsNWidgets(2));
      expect(
        _gapAboveComposer(tester),
        lessThan(20),
        reason:
            'a short, fully-loaded channel must still sit flush against the '
            'composer - the populated branch this fix left untouched',
      );
    },
  );
}
