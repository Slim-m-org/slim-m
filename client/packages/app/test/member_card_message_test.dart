// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member card's Message row closes the card the moment it is tapped, so
/// the request answers into nothing. A refusal used to surface only as an
/// uncaught async error in the log and the person just ended up back where
/// they were; the failure is now said on the host that outlives the card.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/member_profile.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _maya = api.UserProfile(
  id: 'user-maya',
  username: 'maya',
  displayName: 'maya',
  createdAt: 0,
);

http.Response _json(int status, Object body) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> get _conversation => {
  'channel_id': 'chan-1',
  'user': {
    'id': 'user-maya',
    'username': 'maya',
    'display_name': 'maya',
    'created_at': 0,
  },
  'unread': 0,
  'created_at': 0,
};

/// Pumps the card under a router, so a successful open has somewhere to go.
Future<({List<String> requests, List<int> closed})> _pump(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) answer,
) async {
  final requests = <String>[];
  final closed = <int>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(
          body: SingleChildScrollView(
            child: MemberProfileBody(
              profile: _maya,
              compact: false,
              onDone: () => closed.add(1),
            ),
          ),
        ),
      ),
      GoRoute(
        path: '/channels/:id',
        builder: (_, state) =>
            Scaffold(body: Text('conversation ${state.pathParameters['id']}')),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        myPermissionsProvider.overrideWithValue(0),
        membersProvider.overrideWith((ref) async => const []),
        rolesProvider.overrideWith((ref) async => const <api.Role>[]),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith((ref) {
          final built = api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) {
              requests.add('${request.method} ${request.url.path}');
              return answer(request);
            }),
          );
          ref.onDispose(built.close);
          return built;
        }),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return (requests: requests, closed: closed);
}

Future<void> _tapMessage(WidgetTester tester) async {
  await tester.tap(find.text('Message'));
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  testWidgets('a refused DM is reported and throws nothing', (tester) async {
    final run = await _pump(tester, (_) async => _json(403, {'error': 'no'}));

    await _tapMessage(tester);

    expect(run.requests, contains('POST /dms/user-maya'));
    expect(run.closed, hasLength(1));
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Could not open a conversation'),
      findsOneWidget,
    );
  });

  testWidgets('a network failure is reported the same way', (tester) async {
    final run = await _pump(
      tester,
      (_) async => throw http.ClientException('offline'),
    );

    await _tapMessage(tester);

    expect(run.requests, contains('POST /dms/user-maya'));
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('Could not open a conversation'),
      findsOneWidget,
    );
  });

  testWidgets('a DM that opens goes to the conversation and says nothing', (
    tester,
  ) async {
    await _pump(tester, (_) async => _json(200, _conversation));

    await _tapMessage(tester);
    await tester.pumpAndSettle();

    expect(find.text('conversation chan-1'), findsOneWidget);
    expect(find.textContaining('Could not'), findsNothing);
  });
}
