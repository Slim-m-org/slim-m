// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The docked thread pane's three owner-reported defects (backlog seq 176 and
/// 178): the composer takes focus on open, the pane is its own surface, and
/// the transcript is top-anchored with the parent message as its first item.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/composer/providers/composer_focus.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/providers/threads.dart';
import 'package:slimm_app/src/features/messages/screens/thread_screen.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/messages/widgets/message_transcript_widgets.dart';
import 'package:slimm_app/src/features/messages/widgets/thread_parent_card.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';

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
}) => http.Response(
  jsonEncode({
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
  List<api.Message> replies = const [],
  bool docked = true,
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

  await store.applyMessages(replies);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      syncControllerProvider.overrideWith((ref) => StubSyncController(ref)),
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
            if (request.method == 'PUT' && request.url.path.endsWith('/read')) {
              return http.Response(
                jsonEncode({'last_read_seq': 1, 'unread': 0}),
                200,
                headers: {'content-type': 'application/json'},
              );
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
                    builder: (_) => ThreadScreen(
                      channelId: 'c1',
                      onClose: docked ? () {} : null,
                    ),
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

const _parent = 'the original question about the release notes';

http.Response _parentJson() => _threadParentJson(
  parentChannelId: 'parent-channel',
  parentChannelName: 'general',
  parentMessageId: 'parent-1',
  parentContent: _parent,
  parentAuthorId: 'alice',
  parentAuthorDisplayName: 'Alice',
);

api.Message _reply(int seq, String text) => api.Message(
  id: 'r$seq',
  channelId: 'c1',
  authorId: 'alice',
  authorDisplayName: 'Alice',
  seq: seq,
  content: text,
  createdAt: 1000 + seq,
  editedAt: null,
);

Finder get _composerField => find.descendant(
  of: find.byType(Composer),
  matching: find.byType(EditableText),
);

void main() {
  testWidgets('a docked thread focuses its composer when it opens', (
    tester,
  ) async {
    await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _parentJson(),
    );

    expect(
      tester.widget<EditableText>(_composerField).focusNode.hasFocus,
      true,
    );
    await _settle(tester);
  });

  testWidgets('asking again for the open thread puts the caret back in it', (
    tester,
  ) async {
    final container = await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _parentJson(),
    );
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    expect(
      tester.widget<EditableText>(_composerField).focusNode.hasFocus,
      false,
    );

    // The channel's own composer registered last, as it does after a channel switch.
    final channelComposer = FocusNode();
    addTearDown(channelComposer.dispose);
    container.read(composerFocusNodeProvider.notifier).state = channelComposer;
    container.read(openThreadProvider.notifier).state = 'c1';
    dockThread(container, 'c1');
    await tester.pump();

    expect(
      tester.widget<EditableText>(_composerField).focusNode.hasFocus,
      true,
    );
    await _settle(tester);
  });

  testWidgets('a routed (phone) thread leaves the keyboard alone', (
    tester,
  ) async {
    await _pumpThread(
      tester,
      const Size(390, 800),
      threadParentResponse: _parentJson(),
      docked: false,
    );

    expect(
      tester.widget<EditableText>(_composerField).focusNode.hasFocus,
      false,
    );
    await _settle(tester);
  });

  testWidgets('the docked pane paints its own surface, not the chat base', (
    tester,
  ) async {
    await _pumpThread(
      tester,
      const Size(1400, 900),
      threadParentResponse: _parentJson(),
    );

    const tokens = AppTokens.light;
    expect(
      tester.widget<Scaffold>(find.byType(Scaffold).last).backgroundColor,
      tokens.surfaceRaised,
    );
    expect(
      tester.widget<AppBar>(find.byType(AppBar)).backgroundColor,
      tokens.surfaceRaised,
    );
    await _settle(tester);
  });

  testWidgets(
    'the parent is the first item and the reply sits right under it',
    (tester) async {
      await _pumpThread(
        tester,
        const Size(1400, 900),
        threadParentResponse: _parentJson(),
        replies: [_reply(1, 'a first reply')],
      );

      final bar = tester.getRect(find.byType(AppBar));
      final parent = tester.getRect(find.byType(ThreadParentCard));
      final reply = tester.getRect(find.text('a first reply'));
      expect(parent.top - bar.bottom, lessThan(AppSpacing.s24));
      expect(reply.top, greaterThan(parent.bottom));
      expect(reply.top - parent.bottom, lessThan(AppSpacing.s24 * 2));
      final avatars = find.byType(UserAvatar);
      expect(
        tester.getTopLeft(avatars.at(0)).dx,
        tester.getTopLeft(avatars.at(1)).dx,
        reason: 'the parent lines up with the replies, not inset from them',
      );
      expect(find.byType(ChannelStartHeader), findsNothing);
      expect(
        find.text('Replies to the original message appear here.'),
        findsNothing,
      );
      await _settle(tester);
    },
  );

  testWidgets(
    'an empty thread is the parent and one quiet line, top-anchored',
    (tester) async {
      await _pumpThread(
        tester,
        const Size(1400, 900),
        threadParentResponse: _parentJson(),
      );

      final bar = tester.getRect(find.byType(AppBar));
      final parent = tester.getRect(find.byType(ThreadParentCard));
      final note = tester.getRect(find.text('No replies yet'));
      expect(parent.top - bar.bottom, lessThan(AppSpacing.s24));
      expect(note.top, greaterThan(parent.bottom));
      expect(note.top - parent.bottom, lessThan(AppSpacing.s24 * 2));
      expect(
        find.text('Replies to the original message appear here.'),
        findsNothing,
      );
      await _settle(tester);
    },
  );
}
