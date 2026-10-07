// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the threads sheet's empty, loading and error states, the same
/// shape `pinned_messages_sheet_test.dart` already covers for its sibling,
/// plus that tapping a thread closes the sheet and opens it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/widgets/threads_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A real (if minimal) [GoRouter], the same reason
/// `pinned_messages_sheet_test.dart`'s own `_pump` needs one: the sheet
/// captures the router before opening, and tapping a row navigates through it.
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
              onPressed: () => showThreadsSheet(context, channelId),
              child: const Text('open'),
            ),
          ),
        ),
      ),
      GoRoute(
        path: Routes.threadPattern,
        builder: (context, state) =>
            Text('thread ${state.pathParameters['channelId']}'),
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

ProviderContainer _containerAnswering(
  Future<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(handler),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  return container;
}

void main() {
  testWidgets(
    'a failed first load says so and offers a retry that recovers it',
    (tester) async {
      var fail = true;
      final container = _containerAnswering((request) async {
        if (fail) return http.Response('server error', 500);
        return http.Response(
          '[]',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
      addTearDown(container.dispose);

      await _pump(tester, container, 'c1');
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      expect(find.text('Could not load threads.'), findsOneWidget);
      expect(
        find.byType(AppErrorState),
        findsOneWidget,
        reason: 'a failed fetch is the shared persistent error, not bare text',
      );
      expect(
        find.text('No threads yet.'),
        findsNothing,
        reason: 'a failed load must never read as an honest empty state',
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);

      fail = false;
      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();

      expect(find.text('No threads yet.'), findsOneWidget);
      expect(find.text('Could not load threads.'), findsNothing);
    },
  );

  testWidgets('an empty list reads as no threads yet, not an error', (
    tester,
  ) async {
    final container = _containerAnswering(
      (request) async => http.Response(
        '[]',
        200,
        headers: {'content-type': 'application/json'},
      ),
    );
    addTearDown(container.dispose);

    await _pump(tester, container, 'c1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('No threads yet.'), findsOneWidget);
  });

  testWidgets('a 403 explains the denial and offers no retry', (tester) async {
    final container = _containerAnswering(
      (request) async => http.Response('forbidden', 403),
    );
    addTearDown(container.dispose);

    await _pump(tester, container, 'c1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      find.text('You do not have permission to see threads here.'),
      findsOneWidget,
    );
    expect(
      find.text('Retry'),
      findsNothing,
      reason: 'a 403 will not succeed on retry, so none is offered',
    );
  });

  testWidgets('tapping a thread closes the sheet and opens it', (tester) async {
    final container = _containerAnswering((request) async {
      // The row's batch profile lookup answers empty; it falls back to the cached name.
      final body = request.url.path == '/users'
          ? <Map<String, dynamic>>[]
          : [
              {
                'id': 't1',
                'parent_message_id': 'm1',
                'parent_content': 'the original message',
                'parent_author_id': 'other',
                'parent_author_display_name': 'Other',
                'created_at': 0,
                'reply_count': 2,
                'last_reply_at': 1,
                'unread_count': 1,
              },
            ];
      return http.Response(
        jsonEncode(body),
        200,
        headers: {'content-type': 'application/json'},
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container, 'c1');
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('the original message'), findsOneWidget);
    expect(find.text('2 replies'), findsOneWidget);

    await tester.tap(find.text('the original message'));
    await tester.pumpAndSettle();

    expect(
      find.text('No threads yet.'),
      findsNothing,
      reason: 'the sheet must close on the way to the thread',
    );
    expect(find.text('thread t1'), findsOneWidget);
  });
}
