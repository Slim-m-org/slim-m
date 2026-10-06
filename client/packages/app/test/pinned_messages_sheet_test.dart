// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the pinned messages sheet's empty, loading, and error states:
/// a failed first load must say so and offer a retry, never spin forever or
/// read as an honest "nothing pinned".
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/message_jump.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/pinned_messages_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// Stands in for the real [SyncController], which otherwise schedules a real
/// retry timer the moment it sees a signed-in session; see
/// `channel_history_harness.dart`'s own copy of this same seam.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {
    state = SyncStatus.live;
  }
}

/// A real (if minimal) [GoRouter] rather than a bare [MaterialApp]:
/// `showPinnedMessagesSheet` reads the router before opening the sheet, so
/// even a test that never navigates needs one in the tree to open it at all.
Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  String channelId,
) {
  final router = GoRouter(
    initialLocation: '/',
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPinnedMessagesSheet(context, channelId),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.channelPattern,
        builder: (context, state) =>
            Text('channel ${state.pathParameters['channelId']}'),
      ),
    ],
  );
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
}

void main() {
  testWidgets(
    'a failed first load says so and offers a retry that recovers it',
    (tester) async {
      var fail = true;
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (fail) return http.Response('server error', 500);
                return http.Response(
                  '[]',
                  200,
                  headers: {'content-type': 'application/json'},
                );
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      await _pump(tester, container, 'c1');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load pinned messages.'), findsOneWidget);
      expect(
        find.byType(AppErrorState),
        findsOneWidget,
        reason: 'a failed fetch is the shared persistent error, not bare text',
      );
      expect(
        find.text('Nothing pinned yet.'),
        findsNothing,
        reason: 'a failed load must never read as an honest empty state',
      );
      expect(
        find.byType(CircularProgressIndicator),
        findsNothing,
        reason: 'a failure must not spin forever',
      );

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing pinned yet.'), findsOneWidget);
      expect(find.text('Could not load pinned messages.'), findsNothing);
    },
  );

  testWidgets(
    'an empty list stays a modest size instead of a mostly-blank box',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient(
                (request) async => http.Response(
                  '[]',
                  200,
                  headers: {'content-type': 'application/json'},
                ),
              ),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);

      await _pump(tester, container, 'c1');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Nothing pinned yet.'), findsOneWidget);
      final height = tester
          .getSize(find.byKey(pinnedMessagesBodyBoxKey))
          .height;
      expect(
        height,
        lessThan(200),
        reason:
            'a genuinely empty list must not be forced into the same box '
            'a long scrollable list needs',
      );
    },
  );

  testWidgets('a 403 explains the denial and offers no retry', (tester) async {
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              return http.Response('forbidden', 403);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, 'c1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text('You do not have permission to see pins here.'),
      findsOneWidget,
    );
    expect(
      find.text('Retry'),
      findsNothing,
      reason: 'a 403 will not succeed on retry, so none is offered',
    );
  });

  testWidgets('tapping a pinned message closes the sheet and jumps to it', (
    tester,
  ) async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        storeProvider.overrideWith((ref) async => MessageStore(db)),
        syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              // A batch profile lookup for the pin's author answers empty.
              final body = request.url.path == '/users'
                  ? <Map<String, dynamic>>[]
                  : [
                      {
                        'id': 'm1',
                        'channel_id': 'c1',
                        'author_id': 'other',
                        'author_display_name': 'Other',
                        'seq': 1,
                        'content': 'pinned content',
                        'created_at': 0,
                        'edited_at': null,
                        'pinned_at': 0,
                        'pinned_by': 'other',
                      },
                    ];
              return http.Response(
                jsonEncode(body),
                200,
                headers: {'content-type': 'application/json'},
              );
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);

    await _pump(tester, container, 'c1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('pinned content'), findsOneWidget);
    await tester.tap(find.text('pinned content'));
    await tester.pumpAndSettle();

    expect(
      find.text('Nothing pinned yet.'),
      findsNothing,
      reason: 'the sheet must close on the way to the message',
    );
    expect(
      find.text('channel c1'),
      findsOneWidget,
      reason: 'tapping a pin has to reach the message\'s own channel',
    );
    expect(
      container.read(messageJumpProvider),
      isNot(isA<MessageJumpIdle>()),
      reason: 'the jump itself has to actually have been asked for',
    );
  });
}
