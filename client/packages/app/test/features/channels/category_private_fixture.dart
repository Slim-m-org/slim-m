// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fake server for category and channel overwrites, and the scope the
/// Private switch and "Who can see this" tests mount in.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/role_ladder.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const privateTokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const privateRoles = [
  api.Role(
    id: 'everyone',
    name: 'everyone',
    permissions: Perm.viewChannel,
    isEveryone: true,
    createdAt: 0,
  ),
  api.Role(
    id: 'mods',
    name: 'Mods',
    permissions: 0,
    isEveryone: false,
    createdAt: 0,
  ),
];

const privateMembers = [
  api.UserProfile(id: 'ann', username: 'ann', displayName: 'Ann', createdAt: 0),
];

Channel privateChannel(String id, String categoryId) => Channel(
  id: id,
  name: id,
  kind: 'text',
  createdAt: 0,
  position: 0,
  topic: '',
  cursor: 0,
  lastReadSeq: 0,
  mentionedSeq: 0,
  slowModeSeconds: 0,
  joinMuted: false,
  isPersonalSpace: false,
  categoryId: categoryId,
);

/// Overwrites per `/categories/<id>` or `/channels/<id>` path, applied the
/// way the server applies a batch: per entry, an all-zero pair removes it.
class OverwriteServer {
  OverwriteServer(this.rows, {Map<String, bool> synced = const {}})
    : synced = {...synced};

  final Map<String, List<Map<String, Object>>> rows;
  final Map<String, bool> synced;
  final writes = <String, List<Map<String, dynamic>>>{};
  final requests = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final path = request.url.path;
    requests.add('${request.method} $path');
    final base = path.replaceAll(RegExp(r'/overwrites.*$'), '');
    if (request.method == 'POST' && path.endsWith('/sync')) synced[base] = true;
    if (request.method == 'DELETE') {
      final parts = path.split('/');
      rows[base]?.removeWhere(
        (o) => o['kind'] == parts[parts.length - 2] && o['id'] == parts.last,
      );
      return http.Response('', 204);
    }
    if (request.method == 'PUT') {
      final edits = ((jsonDecode(request.body) as Map)['overwrites'] as List)
          .cast<Map<String, dynamic>>();
      writes[base] = edits;
      final list = rows.putIfAbsent(base, () => []);
      for (final e in edits) {
        list.removeWhere((o) => o['kind'] == e['kind'] && o['id'] == e['id']);
        if (e['allow'] != 0 || e['deny'] != 0) {
          list.add(e.cast<String, Object>());
        }
      }
    }
    return http.Response(
      jsonEncode({
        'overwrites': rows[base] ?? const <Object>[],
        if (synced.containsKey(base)) 'synced': synced[base],
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Future<void> pumpPrivate(
  WidgetTester tester,
  OverwriteServer server,
  Widget child, {
  int permissions = Perm.administrator | Perm.manageRoles,
  List<api.UserProfile> members = privateMembers,
}) async {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: privateTokens),
      ),
      rolesProvider.overrideWith((ref) async => privateRoles),
      membersProvider.overrideWith((ref) async => members),
      myPermissionsProvider.overrideWith((ref) => permissions),
      roleLadderProvider.overrideWith(
        (ref) => RoleLadder(permissions: permissions, ranked: false),
      ),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await waitUntil(tester, () => server.requests.isNotEmpty);
}

Future<void> tapAndWait(
  WidgetTester tester,
  Finder finder,
  OverwriteServer server,
) async {
  final before = server.requests.length;
  await tester.tap(finder);
  await waitUntil(tester, () => server.requests.length > before);
}

final privateSwitch = find.byWidgetPredicate((w) => w is AppToggle);

Future<void> turnPrivateOn(WidgetTester tester, OverwriteServer server) async {
  await tester.tap(privateSwitch);
  await pumpFrames(tester);
  await tapAndWait(tester, find.text('Make private'), server);
}
