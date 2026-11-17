// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// One server preview for the role-preview tests (a gamers category holding cs2, and a general
/// channel) and the real shell mounted around it.
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
import 'package:slimm_app/src/features/role_preview/providers/role_preview_controller.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';

const previewTokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const previewRole = api.Role(
  id: 'role-cs',
  name: 'cs',
  permissions: 0,
  isEveryone: false,
  createdAt: 0,
  position: 1,
);

final previewJson = {
  'role_id': previewRole.id,
  'permissions': Perm.viewChannel | Perm.sendMessages,
  'categories': [
    {
      'id': 'cat-gamers',
      'name': 'gamers',
      'position': 0,
      'created_at': 0,
      'parent_id': null,
    },
    {
      'id': 'cat-cs2',
      'name': 'cs2',
      'position': 0,
      'created_at': 0,
      'parent_id': 'cat-gamers',
    },
  ],
  'channels': [
    {
      'id': 'ch-general',
      'name': 'general',
      'kind': 'text',
      'position': 0,
      'category_id': null,
      'permissions': Perm.viewChannel,
      'restricted': false,
    },
    {
      'id': 'ch-cs',
      'name': 'cs-chat',
      'kind': 'text',
      'position': 1,
      'category_id': 'cat-cs2',
      'permissions': Perm.viewChannel | Perm.sendMessages,
      'restricted': true,
    },
  ],
};

/// Answers the preview route with [previewJson], and every other path with a 404.
Future<http.Response> previewHandler(http.Request request) async =>
    request.url.path == '/roles/${previewRole.id}/preview'
    ? http.Response(
        jsonEncode(previewJson),
        200,
        headers: const {'content-type': 'application/json'},
      )
    : http.Response('{"error":"not found"}', 404);

GoRouter _router() => GoRouter(
  initialLocation: '/channels',
  routes: [
    GoRoute(
      path: '/channels',
      builder: (context, state) =>
          const HomeShell(child: Center(child: Text('conversation'))),
    ),
  ],
);

/// Mounts the real shell at [width] on an in-memory store, signed in, with [handler] as the server.
Future<({ProviderContainer container, SlimmDatabase db})> pumpPreviewShell(
  WidgetTester tester, {
  double width = 1280,
  MockClientHandler handler = previewHandler,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: previewTokens),
      ),
      mockApiOverride(handler),
      databaseProvider.overrideWith((ref) => db),
    ],
  );
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: _router(),
      ),
    ),
  );
  await pumpFrames(tester);
  return (container: container, db: db);
}

Future<void> teardownPreviewShell(
  WidgetTester tester,
  ProviderContainer container,
  SlimmDatabase db,
) async {
  await tester.pumpWidget(const SizedBox());
  container.dispose();
  await tester.pump(const Duration(milliseconds: 1));
  await db.close();
}

/// Enters the preview for [previewRole] and lets the shell rebuild.
Future<void> enterPreview(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.runAsync(
    () => container.read(rolePreviewProvider.notifier).enter(previewRole),
  );
  await pumpFrames(tester);
}
