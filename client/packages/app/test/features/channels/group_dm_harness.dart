// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The fixtures the group DM suites share: a fake server for the `/dms/groups`
/// routes, a container over it, and openers for the two sheets.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/group_dm_members_sheet.dart';
import 'package:slimm_app/src/features/channels/widgets/new_group_dm_sheet.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> personJson(String id, String name) => {
  'id': id,
  'username': name.toLowerCase(),
  'display_name': name,
  'created_at': 0,
};

final _everyone = [
  personJson('self', 'Me'),
  for (var i = 1; i <= 10; i++) personJson('u$i', 'Person$i'),
];

Map<String, Object?> groupJson({
  List<String> members = const ['self', 'u1', 'u2'],
  String? name,
}) => {
  'channel_id': 'g1',
  'user': personJson(members.firstWhere((m) => m != 'self'), 'x'),
  'unread': 0,
  'created_at': 1,
  'group': {
    'name': name,
    'members': [
      for (final m in members)
        personJson(m, m == 'self' ? 'Me' : 'Person${m.substring(1)}'),
    ],
  },
};

http.Response jsonResponse(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class GroupDmServer {
  final requests = <String>[];
  Object listing = [groupJson()];
  http.Response? failNext;

  /// The next write is handled but its reply never arrives.
  bool dropNext = false;

  int get writes => requests.where((r) => !r.startsWith('GET')).length;

  Future<http.Response> handle(http.Request request) async {
    final line = '${request.method} ${request.url.path}';
    requests.add(request.body.isEmpty ? line : '$line ${request.body}');
    if (dropNext && request.method != 'GET') {
      dropNext = false;
      throw http.ClientException('connection closed');
    }
    final failure = failNext;
    if (failure != null && request.method != 'GET') {
      failNext = null;
      return failure;
    }
    switch (line) {
      case 'GET /members':
        return jsonResponse(_everyone);
      case 'GET /users':
        return jsonResponse(<Object>[]);
      case 'GET /dms':
        return jsonResponse(listing);
      case 'POST /dms/groups':
        return jsonResponse(groupJson(), 201);
      case 'POST /dms/groups/g1/members':
        return jsonResponse(
          groupJson(members: const ['self', 'u1', 'u2', 'u3']),
        );
      case 'PATCH /dms/groups/g1':
        return jsonResponse(groupJson(name: 'trip'));
      case 'POST /dms/groups/g1/leave':
        return http.Response('', 204);
    }
    if (request.url.path.endsWith('/voice/roster')) {
      return jsonResponse({'participants': <Object>[]});
    }
    return http.Response('', 204);
  }
}

ProviderContainer groupDmContainer(GroupDmServer server) {
  final db = SlimmDatabase(NativeDatabase.memory());
  return ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      databaseProvider.overrideWith((ref) async {
        ref.onDispose(db.close);
        return db;
      }),
      mockApiOverride(server.handle),
    ],
  );
}

Future<void> pumpGroupDm(
  WidgetTester tester,
  ProviderContainer container,
  Widget home, {
  Size size = const Size(1280, 900),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final router = GoRouter(
    routes: [
      GoRoute(
        path: '/',
        builder: (_, _) => Scaffold(body: home),
      ),
      GoRoute(
        path: '/channels/:id',
        builder: (_, state) => Text('open:${state.pathParameters['id']}'),
      ),
      GoRoute(path: '/channels', builder: (_, _) => const Text('rail')),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
}

Future<void> finishGroupDm(
  WidgetTester tester,
  ProviderContainer container,
) async {
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
}

Finder personTile(String id) => find.byKey(ValueKey('group-dm-person:$id'));

/// Opens the new-group sheet over a fresh server, returning the server.
Future<GroupDmServer> openNewGroupSheet(
  WidgetTester tester, {
  Size? size,
}) async {
  final server = GroupDmServer();
  final container = groupDmContainer(server);
  addTearDown(container.dispose);
  await pumpGroupDm(
    tester,
    container,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showNewGroupDmSheet(context),
        child: const Text('open'),
      ),
    ),
    size: size ?? const Size(1280, 900),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(seconds: 1));
  await waitUntil(
    tester,
    () => server.requests.any((r) => r.startsWith('GET /')),
  );
  return server;
}

/// Opens group g1's members sheet over a fresh server, returning the server.
Future<GroupDmServer> openMembersSheet(
  WidgetTester tester, {
  Size? size,
}) async {
  final server = GroupDmServer();
  final container = groupDmContainer(server);
  addTearDown(container.dispose);
  await pumpGroupDm(
    tester,
    container,
    Builder(
      builder: (context) => TextButton(
        onPressed: () => showGroupDmMembersSheet(context, 'g1'),
        child: const Text('open'),
      ),
    ),
    size: size ?? const Size(1280, 900),
  );
  await tester.tap(find.text('open'));
  await tester.pump(const Duration(seconds: 1));
  await waitUntil(
    tester,
    () => server.requests.any((r) => r.startsWith('GET /')),
  );
  return server;
}
