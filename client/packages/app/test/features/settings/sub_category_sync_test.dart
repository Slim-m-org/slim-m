// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A sub-category's permissions say whether it follows its parent's, and
/// "Sync with parent category" brings it back (decision 0120). A top-level
/// category follows nothing, so it shows no such line.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/admin/category_sync_banner.dart';
import 'package:slimm_app/src/providers/providers.dart';
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

class _Server {
  _Server({this.synced});

  bool? synced;
  final requests = <String>[];

  Future<http.Response> handle(http.Request request) async {
    final key = '${request.method} ${request.url.path}';
    requests.add(key);
    if (key == 'POST /categories/cs2/overwrites/sync') synced = true;
    return http.Response(
      jsonEncode({'overwrites': const <Object>[], 'synced': ?synced}),
      200,
      headers: const {'content-type': 'application/json'},
    );
  }
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: CategorySyncBanner.forSubCategory(categoryId: 'cs2'),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
}

bool _shown(String text) => find.text(text).evaluate().isNotEmpty;

void main() {
  testWidgets('a sub-category with its own permissions syncs back to its '
      'parent', (tester) async {
    final server = _Server(synced: false);
    await _pump(tester, server);

    expect(_shown('Has its own permissions.'), isTrue);
    await tester.tap(find.text('Sync with parent category'));
    await pumpFrames(tester);
    await tester.tap(find.text('Sync'));
    await pumpFrames(tester);

    expect(server.requests, contains('POST /categories/cs2/overwrites/sync'));
    expect(_shown("Follows its parent category's permissions."), isTrue);
    expect(_shown('Sync with parent category'), isFalse);
  });

  testWidgets('a top-level category shows no sync line', (tester) async {
    final server = _Server();
    await _pump(tester, server);

    expect(server.requests, contains('GET /categories/cs2/overwrites'));
    expect(_shown('Has its own permissions.'), isFalse);
    expect(_shown("Follows its parent category's permissions."), isFalse);
  });
}
