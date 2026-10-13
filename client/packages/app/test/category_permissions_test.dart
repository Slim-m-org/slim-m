// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Category permissions (decision 0064) from the client: the grid in category
/// mode saves to the category, and a channel's banner says whether it follows
/// its category and syncs it back.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/channel_permissions.dart';
import 'package:slimm_app/src/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/category_sync_banner.dart';
import 'package:slimm_app/src/screens/admin/channel_permissions_grid.dart';
import 'package:slimm_data/data.dart' show Channel;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _everyone = api.Role(
  id: 'role-everyone',
  name: 'everyone',
  permissions: 0,
  isEveryone: true,
  createdAt: 0,
);

final _channel = Channel(
  id: 'c-plans',
  name: 'plans',
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
  categoryId: 'cat-1',
);

class _Server {
  bool synced = false;
  final requests = <String>[];
  final bodies = <String, Object?>{};

  Future<http.Response> handle(http.Request request) async {
    final key = '${request.method} ${request.url.path}';
    requests.add(key);
    if (request.body.isNotEmpty) bodies[key] = jsonDecode(request.body);
    if (key == 'POST /channels/c-plans/overwrites/sync') synced = true;
    return http.Response(
      jsonEncode({
        'overwrites': const [],
        if (request.url.path.startsWith('/channels/')) 'synced': synced,
      }),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

ProviderContainer _container(_Server server) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      rolesProvider.overrideWith((ref) async => [_everyone]),
      membersProvider.overrideWith((ref) async => const []),
      myPermissionsProvider.overrideWith(
        (ref) => Perm.viewChannel | Perm.manageRoles,
      ),
      myChannelPermissionsProvider(
        _channel.id,
      ).overrideWith((ref) => Perm.viewChannel | Perm.manageRoles),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(server.handle),
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _pump(WidgetTester tester, _Server server, Widget child) async {
  tester.view.physicalSize = const Size(1000, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: _container(server),
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the category grid loads and saves to the category', (
    tester,
  ) async {
    final server = _Server();
    await _pump(
      tester,
      server,
      const ChannelPermissionsGrid.forCategory(categoryId: 'cat-1'),
    );
    expect(server.requests, contains('GET /categories/cat-1/overwrites'));

    final cell = find.byKey(
      ValueKey('cell:role:role-everyone:${Perm.viewChannel}'),
    );
    await tester.ensureVisible(cell);
    await tester.tap(cell);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save changes'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.text('Save changes'));
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pumpAndSettle();

    final body =
        server.bodies['PUT /categories/cat-1/overwrites']
            as Map<String, dynamic>?;
    expect(body, isNotNull, reason: 'saved to the category');
    final entry = (body!['overwrites'] as List).single as Map<String, dynamic>;
    expect(entry['id'], 'role-everyone');
    expect(server.requests.where((r) => r.contains('/channels/')), isEmpty);
  });

  testWidgets('an unsynced channel says so and syncs back to its category', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, const CategorySyncBanner(channelId: 'c-plans'));
    expect(find.text('Has its own permissions.'), findsOneWidget);

    await tester.tap(find.text('Sync with category'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sync'));
    await tester.pumpAndSettle();

    expect(server.requests, contains('POST /channels/c-plans/overwrites/sync'));
    expect(find.text("Follows its category's permissions."), findsOneWidget);
  });

  testWidgets('the channel grid shows the banner only for a filed channel', (
    tester,
  ) async {
    final server = _Server()..synced = true;
    await _pump(tester, server, ChannelPermissionsGrid(channel: _channel));
    expect(find.byType(CategorySyncBanner), findsOneWidget);
    expect(find.text("Follows its category's permissions."), findsOneWidget);
  });
}
