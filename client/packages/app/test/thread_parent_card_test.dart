// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ThreadParentCard`, split out of `thread_screen_test.dart` for the file
/// budget: before it existed, `threadParentProvider`'s answer was only ever
/// read for the AppBar title, and the message a thread was actually about
/// never appeared anywhere in the panel.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/screens/thread_screen.dart';
import 'package:slimm_app/src/widgets/thread_parent_card.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

/// See `channel_screen_test.dart`'s own copy for why: the real
/// `SyncController` opens a websocket to a server that does not exist here.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {}
}

const _tokens = api.TokenPair(
  userId: 'bob',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _meJson() => {
  'id': 'bob',
  'username': 'bob',
  'display_name': 'Bob',
  'created_at': 0,
  'permissions': 0,
};

http.Response _emptyJsonList() => http.Response(
  jsonEncode([]),
  200,
  headers: {'content-type': 'application/json'},
);

/// Every author id these tests ever attribute a message to, so `GET /users`
/// (the batch profile lookup `ThreadParentCard` triggers to keep a cached
/// name fresh) answers with a real profile instead of "not found", which
/// would otherwise overwrite the parent's own cached display name.
const _knownAuthors = {'alice': 'Alice'};

/// Author ids that resolve as a webhook, over and above [_knownAuthors].
const _knownWebhooks = {'webhook-1'};

http.Response _usersJson(Uri url) {
  final ids = url.queryParameters['ids']?.split(',') ?? const [];
  final profiles = [
    for (final id in ids)
      if (_knownAuthors[id] case final name?)
        {'id': id, 'username': id, 'display_name': name, 'created_at': 0}
      else if (_knownWebhooks.contains(id))
        {
          'id': id,
          'username': id,
          'display_name': id,
          'created_at': 0,
          'is_webhook': true,
        },
  ];
  return http.Response(
    jsonEncode(profiles),
    200,
    headers: {'content-type': 'application/json'},
  );
}

/// `GET /channels/c1/thread-parent`'s answer, matching
/// `thread_screen_test.dart`'s own copy.
http.Response _threadParentJson({
  String? parentChannelId,
  String? parentChannelName,
  String? parentMessageId,
  String? parentContent,
  bool parentDeleted = false,
  String? parentAuthorId,
  String? parentAuthorDisplayName,
  List<Map<String, Object>> parentAttachments = const [],
}) => http.Response(
  jsonEncode({
    'parent_attachments': parentAttachments,
    'parent_channel_id': parentChannelId,
    'parent_channel_name': parentChannelName,
    'parent_message_id': parentMessageId,
    'parent_content': parentContent,
    'parent_deleted': parentDeleted,
    'parent_author_id': parentAuthorId,
    'parent_author_display_name': parentAuthorDisplayName,
  }),
  200,
  headers: {'content-type': 'application/json'},
);

/// Pumps a [ThreadScreen] for channel `c1`, a thread (`parentMessageId` set),
/// reached by pushing it over a marker screen - `thread_screen_test.dart`'s
/// own copy, kept in step since a shared helper library would cost this
/// pair of files a third source to keep synchronized instead of a second.
Future<ProviderContainer> _pumpThread(
  WidgetTester tester,
  Size size, {
  http.Response? threadParentResponse,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertChannels([
    const api.Channel(
      id: 'c1',
      name: '',
      kind: 'text',
      createdAt: 0,
      parentMessageId: 'parent-1',
    ),
  ]);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                jsonEncode(_meJson()),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' &&
                request.url.path == '/channels/c1/thread-parent') {
              return threadParentResponse ?? _threadParentJson();
            }
            if (request.method == 'GET' && request.url.path == '/users') {
              return _usersJson(request.url);
            }
            return _emptyJsonList();
          }),
        );
        ref.onDispose(client.close);
        return client;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ThreadScreen(channelId: 'c1'),
                  ),
                ),
                child: const Text('open thread'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open thread'));
  // A bounded pump count, not pumpAndSettle: AppIconButton's ripple keeps requesting a frame.
  for (var i = 0; i < 15; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
  return container;
}

/// Unmounts before the framework's own teardown does - see
/// `thread_screen_test.dart`'s own copy for why.
Future<void> _settle(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  testWidgets('a thread with a known parent renders it above the transcript', (
    tester,
  ) async {
    await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _threadParentJson(
        parentChannelId: 'parent-channel',
        parentChannelName: 'general',
        parentMessageId: 'parent-1',
        parentContent: 'the original question',
        parentAuthorId: 'alice',
        parentAuthorDisplayName: 'Alice',
      ),
    );

    expect(find.byType(ThreadParentCard), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('the original question'), findsOneWidget);

    await _settle(tester);
  });

  testWidgets(
    'a thread whose parent is a webhook post shows its badge, at phone '
    'width',
    (tester) async {
      await _pumpThread(
        tester,
        const Size(360, 800),
        threadParentResponse: _threadParentJson(
          parentChannelId: 'parent-channel',
          parentChannelName: 'general',
          parentMessageId: 'parent-1',
          parentContent: 'the disk is nearly full',
          parentAuthorId: 'webhook-1',
          parentAuthorDisplayName: 'Definitely A Real Person ' * 8,
        ),
      );

      expect(
        find.text('WEBHOOK'),
        findsOneWidget,
        reason:
            'docs/decisions/0030 calls this badge the entire mitigation for '
            "a webhook's claimed name",
      );
      expect(tester.getRect(find.byType(AppBadge)).width, greaterThan(0));

      await _settle(tester);
    },
  );

  /// The parent message can be soft-deleted while its thread stays open -
  /// the two are unrelated deletes - so the card must say so rather than
  /// rendering blank or throwing on the missing content and author.
  testWidgets(
    'a thread whose parent was deleted renders the deleted state, not '
    'blank',
    (tester) async {
      await _pumpThread(
        tester,
        const Size(1400, 900),
        threadParentResponse: _threadParentJson(
          parentChannelId: 'parent-channel',
          parentChannelName: 'general',
          parentMessageId: 'parent-1',
          parentDeleted: true,
        ),
      );

      expect(find.byType(ThreadParentCard), findsOneWidget);
      expect(find.text('This message was deleted.'), findsOneWidget);

      await _settle(tester);
    },
  );

  testWidgets("the parent's attachments show in the parent block", (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _threadParentJson(
        parentChannelId: 'parent-channel',
        parentChannelName: 'general',
        parentMessageId: 'parent-1',
        parentContent: 'see the attached steps',
        parentAuthorId: 'alice',
        parentAuthorDisplayName: 'Alice',
        parentAttachments: const [
          {
            'id': 'att-1',
            'filename': 'repro-steps.pdf',
            'content_type': 'application/pdf',
            'size': 48213,
          },
        ],
      ),
    );
    expect(find.text('repro-steps.pdf'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp(r'with an attachment')),
      findsOneWidget,
    );
    semantics.dispose();
    await _settle(tester);
  });
}
