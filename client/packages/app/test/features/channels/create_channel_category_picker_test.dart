// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The create-channel sheet lets the creator pick the category (the top-level
/// `+` and the Space menu named none, so a channel could only land
/// uncategorised and needed a drag straight afterwards).
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/widgets/create_channel_sheet.dart';
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

Future<List<http.Request>> _open(
  WidgetTester tester, {
  String? categoryId,
  List<api.ChannelCategory> categories = const [
    api.ChannelCategory(id: 'dev', name: 'dev', position: 0, createdAt: 0),
    api.ChannelCategory(id: 'fun', name: 'fun', position: 1, createdAt: 0),
  ],
}) async {
  final requests = <http.Request>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await tester.runAsync(() => store.replaceCategories(categories));
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      mockApiOverride((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'c1',
            'name': 'ideas',
            'kind': 'text',
            'position': 0,
            'created_at': 0,
          }),
          200,
        );
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: GoRouter(
          routes: [
            GoRoute(
              path: '/',
              builder: (context, _) => Scaffold(
                body: TextButton(
                  onPressed: () => showCreateChannelSheet(
                    context,
                    initialKind: 'text',
                    categoryId: categoryId,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
            GoRoute(path: '/channels/:id', builder: (_, _) => const SizedBox()),
          ],
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester);
  return requests;
}

Finder get _name => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Channel name',
);

Future<void> _close(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
}

bool _shown(String text) => find.text(text).evaluate().isNotEmpty;

void main() {
  testWidgets('the picker starts on the category the sheet was opened from', (
    tester,
  ) async {
    await _open(tester, categoryId: 'fun');

    expect(_shown('Category'), isTrue);
    expect(_shown('fun'), isTrue);
    await _close(tester);
  });

  testWidgets('picking a category sends it with the channel', (tester) async {
    final requests = await _open(tester);

    expect(_shown('No category'), isTrue);
    await tester.tap(find.text('No category'));
    await pumpFrames(tester);
    await tester.tap(find.text('dev').last);
    await pumpFrames(tester);
    await tester.enterText(_name, 'ideas');
    await tester.pump();
    await tester.tap(find.text('Create channel'));
    await pumpFrames(tester);

    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), containsPair('category_id', 'dev'));
  });

  testWidgets('a deployment with no categories is offered no picker', (
    tester,
  ) async {
    await _open(tester, categories: const []);

    expect(_shown('Category'), isFalse);
    await _close(tester);
  });
}
