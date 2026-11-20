// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Creating a category inside a top-level one (decision 0120): the sheet
/// offers a parent on a server that nests, starts on the header it was opened
/// from, and sends that parent.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/category_nesting.dart';
import 'package:slimm_app/src/features/channels/widgets/create_category_sheet.dart';
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
  String? parentId,
  bool nests = true,
  bool gamersFileable = true,
}) async {
  final requests = <http.Request>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await tester.runAsync(
    () => store.replaceCategories([
      api.ChannelCategory(
        id: 'gamers',
        name: 'gamers',
        position: 0,
        createdAt: 0,
        fileable: gamersFileable,
      ),
      const api.ChannelCategory(
        id: 'cs2',
        name: 'cs2',
        position: 0,
        createdAt: 0,
        parentId: 'gamers',
      ),
    ]),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      storeProvider.overrideWith((ref) async => store),
      categoriesNestProvider.overrideWith((ref) => nests),
      mockApiOverride((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'id': 'minecraft',
            'name': 'minecraft',
            'position': 1,
            'created_at': 0,
            'parent_id': 'gamers',
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
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () =>
                  showCreateCategorySheet(context, parentId: parentId),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester);
  return requests;
}

Finder get _name => find.byWidgetPredicate(
  (w) => w is AppInput && w.placeholder == 'Category name',
);

bool _shown(String text) => find.text(text).evaluate().isNotEmpty;

void main() {
  testWidgets('opened from a header, it starts inside that category and '
      'sends it as the parent', (tester) async {
    final requests = await _open(tester, parentId: 'gamers');

    expect(_shown('Create a sub-category'), isTrue);
    expect(_shown('Parent category'), isTrue);
    expect(_shown('cs2'), isFalse, reason: 'a sub-category is never a parent');
    await tester.enterText(_name, 'minecraft');
    await tester.pump();
    await tester.tap(find.text('Create category'));
    await pumpFrames(tester);

    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), containsPair('parent_id', 'gamers'));
    expect(_shown('Create a sub-category'), isFalse, reason: 'it closed');
  });

  testWidgets('a parent nothing may be filed under is neither offered nor '
      'sent', (tester) async {
    final requests = await _open(
      tester,
      parentId: 'gamers',
      gamersFileable: false,
    );

    expect(_shown('Create a category'), isTrue);
    expect(_shown('Parent category'), isFalse, reason: 'no parent is left');
    await tester.enterText(_name, 'minecraft');
    await tester.pump();
    await tester.tap(find.text('Create category'));
    await pumpFrames(tester);

    final post = requests.singleWhere((r) => r.method == 'POST');
    expect(jsonDecode(post.body), isNot(contains('parent_id')));
  });

  testWidgets('an older server is offered no parent at all', (tester) async {
    await _open(tester, nests: false);

    expect(_shown('Create a category'), isTrue);
    expect(_shown('Parent category'), isFalse);
  });
}
