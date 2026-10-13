// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a private channel lets the creator pick who can see it, and the
/// picks are written as view overwrites right after the channel exists.
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
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/create_channel_sheet.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _mods = api.Role(
  id: 'role-mods',
  name: 'Mods',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

api.UserProfile _member(String id, String name) => api.UserProfile(
  id: id,
  username: name.toLowerCase(),
  displayName: name,
  createdAt: 0,
);

class _Server {
  final created = <Map<String, dynamic>>[];
  final overwrites = <Map<String, dynamic>>[];
  bool failOverwrites = false;

  Future<http.Response> handle(http.Request request) async {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    if (request.method == 'POST') {
      created.add(body);
      return http.Response(
        jsonEncode({
          'id': body['id'],
          'name': body['name'],
          'kind': 'text',
          'created_at': 0,
          'position': 0,
          'topic': '',
        }),
        200,
        headers: {'content-type': 'application/json'},
      );
    }
    if (failOverwrites) return http.Response('{"error":"boom"}', 500);
    overwrites.addAll((body['overwrites'] as List<dynamic>).cast());
    return http.Response(
      jsonEncode({'overwrites': <Object>[]}),
      200,
      headers: {'content-type': 'application/json'},
    );
  }
}

Future<void> _open(WidgetTester tester, _Server server) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (context, _) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showCreateChannelSheet(context, initialKind: 'text'),
            child: const Text('open'),
          ),
        ),
      ),
      GoRoute(path: '/:rest(.*)', builder: (_, __) => const Scaffold()),
    ],
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
        myPermissionsProvider.overrideWithValue(Perm.manageRoles),
        rolesProvider.overrideWith((ref) async => [_everyone, _mods]),
        membersProvider.overrideWith(
          (ref) async => [_member('self', 'Nick'), _member('m-nadia', 'Nadia')],
        ),
        storeProvider.overrideWith((ref) async => store),
        apiProvider.overrideWith(
          (ref) => api.SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: api.SessionStore(tokens: _tokens),
            httpClient: MockClient(server.handle),
          ),
        ),
      ],
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byWidgetPredicate(
      (w) => w is AppInput && w.placeholder == 'Channel name',
    ),
    'staff',
  );
  await tester.tap(find.bySemanticsLabel('Make this channel private'));
  await tester.pumpAndSettle();
}

Future<void> _create(WidgetTester tester) async {
  await tester.runAsync(() async {
    await tester.tap(find.text('Create channel'));
    await Future<void>.delayed(const Duration(milliseconds: 300));
  });
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the picker offers roles and members but not everyone or you', (
    tester,
  ) async {
    await _open(tester, _Server());

    expect(
      find.byKey(const ValueKey('audience:role:role-mods')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audience:member:m-nadia')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('audience:role:role-everyone')),
      findsNothing,
    );
    expect(find.byKey(const ValueKey('audience:member:self')), findsNothing);
    expect(
      find.textContaining('Administrator or Manage channels'),
      findsOneWidget,
    );
  });

  testWidgets('picked roles and members are written as view grants', (
    tester,
  ) async {
    final server = _Server();
    await _open(tester, server);
    await tester.tap(find.byKey(const ValueKey('audience:role:role-mods')));
    await tester.tap(find.byKey(const ValueKey('audience:member:m-nadia')));
    await tester.pump();
    await _create(tester);

    expect(server.created.single['restricted'], isTrue);
    expect(server.overwrites, hasLength(2));
    expect(
      {
        for (final o in server.overwrites)
          '${o['kind']}:${o['id']}': o['allow'],
      },
      {'role:role-mods': Perm.viewChannel, 'member:m-nadia': Perm.viewChannel},
    );
  });

  testWidgets('nobody picked writes no overwrites', (tester) async {
    final server = _Server();
    await _open(tester, server);
    await _create(tester);

    expect(server.created.single['restricted'], isTrue);
    expect(server.overwrites, isEmpty);
  });

  testWidgets('a failed grant keeps the sheet open with a clear error', (
    tester,
  ) async {
    final server = _Server()..failOverwrites = true;
    await _open(tester, server);
    await tester.tap(find.byKey(const ValueKey('audience:role:role-mods')));
    await tester.pump();
    await _create(tester);

    expect(find.textContaining('The channel was created'), findsOneWidget);
    expect(find.text('Create channel'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });
}
