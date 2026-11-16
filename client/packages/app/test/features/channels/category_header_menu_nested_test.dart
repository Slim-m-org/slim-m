// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header menu on a server that nests categories (decision 0120): a
/// top-level header offers a sub-category, a sub-category can move back out,
/// and an older server is offered none of it.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/category_nesting.dart';
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/features/channels/widgets/category_header_menu.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import '../../support/fake_api.dart';
import '../../support/menu_gestures.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _gamers = ChannelCategoryRow(id: 'gamers', name: 'gamers', position: 0);
const _cs2 = ChannelCategoryRow(
  id: 'cs2',
  name: 'cs2',
  position: 0,
  parentId: 'gamers',
);
const _music = ChannelCategoryRow(id: 'music', name: 'music', position: 1);
const _categories = [_gamers, _cs2, _music];

Future<List<http.Request>> _pump(
  WidgetTester tester,
  ChannelCategoryRow category, {
  bool nests = true,
  Set<String> collapsed = const {},
}) async {
  SharedPreferences.setMockInitialValues({
    collapsedCategoriesKey: collapsed.toList(),
  });
  final requests = <http.Request>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      databaseProvider.overrideWith((ref) => db),
      categoriesNestProvider.overrideWith((ref) => nests),
      mockApiOverride((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'cs2',
            'name': 'cs2',
            'position': 2,
            'created_at': 0,
            'parent_id': null,
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
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: CategoryHeaderMenu(
            category: category,
            categories: _categories,
            collapsed: collapsed,
            label: Text(category.name),
          ),
        ),
      ),
    ),
  );
  await rightClickMenu(tester, find.text(category.name));
  return requests;
}

bool _offered(String label) => find.text(label).evaluate().isNotEmpty;

void main() {
  testWidgets('a top-level header with sub-categories offers a new one, and '
      'no way to file it under another', (tester) async {
    await _pump(tester, _gamers);

    expect(_offered('Create sub-category...'), isTrue);
    expect(_offered('Move into...'), isFalse);
    expect(_offered('Move category down'), isTrue);
  });

  testWidgets('a sub-category moves among its siblings and back out', (
    tester,
  ) async {
    final requests = await _pump(tester, _cs2);

    expect(_offered('Create sub-category...'), isFalse);
    expect(_offered('Move category up'), isFalse, reason: 'its only sibling');
    expect(_offered('Move into...'), isTrue);

    await tester.tap(find.text('Move out of gamers'));
    await pumpFrames(tester);

    final moves = requests.where((r) => r.method == 'PATCH');
    expect(moves.single.url.path, '/categories/cs2');
    expect(jsonDecode(moves.single.body), {'parent_id': null});
  });

  testWidgets('an older server is offered no nesting at all', (tester) async {
    await _pump(tester, _music, nests: false);

    expect(_offered('Create sub-category...'), isFalse);
    expect(_offered('Move into...'), isFalse);
    expect(_offered('Rename category...'), isTrue);
  });

  testWidgets('a sub-category under a folded parent offers to expand, which '
      'opens the parent too', (tester) async {
    await _pump(tester, _cs2, collapsed: {'gamers', 'music'});

    expect(_offered('Collapse category'), isFalse);
    await tester.tap(find.text('Expand category'));
    await pumpFrames(tester);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(collapsedCategoriesKey), ['music']);
  });
}
