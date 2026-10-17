// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Two consecutive posts from one webhook under different usernames each show
/// their own label; grouping used to compare authors only, so the second
/// label never rendered.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Message;
import 'package:slimm_app/src/features/channels/providers/channel_history.dart';
import 'package:slimm_app/src/providers/message_extras.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/user_profiles.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/widgets/message_transcript.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'message_row_harness.dart';
import 'ui_snapshot_support.dart';
import 'support/fake_sync.dart';

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

class _SeededExtras extends MessageExtrasController {
  _SeededExtras(super.ref, Map<String, MessageExtras> seed) {
    state = seed;
  }
}

Message _post(String id, int seq, {String author = 'w1'}) => Message(
  id: id,
  channelId: 'c1',
  authorId: author,
  authorDisplayName: 'CI Bot',
  seq: seq,
  content: 'body $id',
  createdAt: 1000 + seq,
  pending: false,
  failed: false,
);

Future<void> _pump(
  WidgetTester tester,
  List<Message> messages,
  Map<String, String> usernames,
) async {
  late BatchProfilesController profiles;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        ..._overrides(),
        messageExtrasProvider.overrideWith(
          (ref) => _SeededExtras(ref, {
            for (final e in usernames.entries)
              e.key: MessageExtras(webhookUsername: e.value),
          }),
        ),
        batchProfilesControllerProvider.overrideWith((ref) {
          profiles = BatchProfilesController(ref);
          return profiles;
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: RepaintBoundary(
            key: snapshotBoundary,
            child: _transcript(messages: messages),
          ),
        ),
      ),
    ),
  );
  profiles.state = {
    ...profiles.state,
    'w1': const UserProfile(
      id: 'w1',
      username: 'webhook-w1',
      displayName: 'CI Bot',
      createdAt: 0,
      isWebhook: true,
    ),
  };
  await tester.pump();
}

void main() {
  _snapshotCases();

  testWidgets('a different webhook username starts a new group', (
    tester,
  ) async {
    await _pump(
      tester,
      [_post('a', 1), _post('b', 2)],
      {'a': 'Grafana', 'b': 'Sentry'},
    );

    expect(find.text('Grafana'), findsOneWidget);
    expect(find.text('Sentry'), findsOneWidget);
  });

  testWidgets('the same webhook username still groups under one label', (
    tester,
  ) async {
    await _pump(
      tester,
      [_post('a', 1), _post('b', 2)],
      {'a': 'Grafana', 'b': 'Grafana'},
    );

    expect(find.text('Grafana'), findsOneWidget);
  });

  testWidgets('a non-webhook author with no username still groups', (
    tester,
  ) async {
    await _pump(tester, [_post('a', 1), _post('b', 2)], const {});

    expect(find.text('CI Bot'), findsOneWidget);
  });
}

void _snapshotCases() {
  for (final (name, size) in [
    ('phone', const Size(390, 420)),
    ('desktop', const Size(1100, 420)),
  ]) {
    testWidgets('renders a picture at $name width', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        [_post('a', 1), _post('b', 2), _post('c', 3), _post('d', 4)],
        {'a': 'Grafana', 'b': 'Grafana', 'c': 'Sentry', 'd': 'Sentry'},
      );

      expect(find.text('Grafana'), findsOneWidget);
      expect(find.text('Sentry'), findsOneWidget);
      await writeSnapshot(tester, 'webhook-label-grouping-$name');
    });
  }
}
