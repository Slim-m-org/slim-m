// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The category header's own menu (design review note 8): move up/down's
/// boundary gating, and that collapse actually flips the stored fold state.
/// Rename and delete are already covered by `manage_category_sheet.dart`'s
/// own callers.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind, kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/collapsed_categories_preference.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/category_header_menu.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_sections.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

const _categories = [
  ChannelCategoryRow(id: 'cat-a', name: 'General', position: 0),
  ChannelCategoryRow(id: 'cat-b', name: 'Voice', position: 1),
];

({ProviderContainer container, List<http.Request> requests, SlimmDatabase db})
_setup() {
  final requests = <http.Request>[];
  SharedPreferences.setMockInitialValues({});
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      preferencesProvider.overrideWith(
        (ref) => SharedPreferences.getInstance(),
      ),
      databaseProvider.overrideWith((ref) => db),
      mockApiOverride((request) async {
        requests.add(request);
        if (request.method == 'PATCH' &&
            request.url.path.startsWith('/categories/')) {
          final id = request.url.path.split('/').last;
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          final existing = _categories.firstWhere((c) => c.id == id);
          return http.Response(
            jsonEncode({
              'id': id,
              'name': body['name'] as String? ?? existing.name,
              'position': body['position'] as int? ?? existing.position,
              'created_at': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      }),
    ],
  );
  return (container: container, requests: requests, db: db);
}

Future<void> _pump(
  WidgetTester tester,
  ProviderContainer container,
  ChannelCategoryRow category,
) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: CategoryHeaderMenu(
            category: category,
            categories: _categories,
            collapsed: const {},
            label: Text(category.name),
          ),
        ),
      ),
    ),
  );
}

/// The real sections as the rail renders them, so a held header can be carried onto the other.
Future<void> _pumpBoth(WidgetTester tester, ProviderContainer container) {
  return tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ChannelCategorySections(
              channels: const [],
              categories: _categories,
              selectedId: null,
              canManage: true,
              onReorder: (_) {},
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tapAt(
    tester.getCenter(find.byType(CategoryHeaderMenu)),
    buttons: kSecondaryButton,
    kind: PointerDeviceKind.mouse,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the first category offers no "Move up"', (tester) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);
    addTearDown(setup.db.close);
    await _pump(tester, setup.container, _categories[0]);

    await _openMenu(tester);

    expect(find.text('Move category up'), findsNothing);
    expect(find.text('Move category down'), findsOneWidget);
  });

  testWidgets('the last category offers no "Move down"', (tester) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);
    addTearDown(setup.db.close);
    await _pump(tester, setup.container, _categories[1]);

    await _openMenu(tester);

    expect(find.text('Move category up'), findsOneWidget);
    expect(find.text('Move category down'), findsNothing);
  });

  testWidgets(
    'moving the first category down swaps it past the second, one PATCH '
    'per category at its new position',
    (tester) async {
      final setup = _setup();
      addTearDown(setup.container.dispose);
      addTearDown(setup.db.close);
      await _pump(tester, setup.container, _categories[0]);

      await _openMenu(tester);
      await tester.tap(find.text('Move category down'));
      await tester.pumpAndSettle();

      final patches = setup.requests.where((r) => r.method == 'PATCH').toList();
      expect(patches, hasLength(2));
      final positions = {
        for (final r in patches)
          r.url.path.split('/').last:
              (jsonDecode(r.body) as Map<String, dynamic>)['position'],
      };
      expect(positions, {
        'cat-b': 0,
        'cat-a': 1,
      }, reason: 'cat-a moved past cat-b, so cat-b is now first');
    },
  );

  testWidgets(
    'holding the first header and carrying it past the second reorders '
    'exactly the way "Move category down" does - the channels never move, '
    'only the category list order',
    (tester) async {
      final setup = _setup();
      addTearDown(setup.container.dispose);
      addTearDown(setup.db.close);
      await _pumpBoth(tester, setup.container);

      final from = tester.getCenter(find.text('General'));
      final gesture = await tester.startGesture(
        from,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump(const Duration(milliseconds: 400));
      final end =
          tester.getBottomLeft(find.text('Voice')) + const Offset(10, 30);
      for (var i = 1; i <= 10; i++) {
        await gesture.moveTo(Offset.lerp(from, end, i / 10)!);
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final patches = setup.requests.where((r) => r.method == 'PATCH').toList();
      expect(patches, hasLength(2));
      final positions = {
        for (final r in patches)
          r.url.path.split('/').last:
              (jsonDecode(r.body) as Map<String, dynamic>)['position'],
      };
      expect(positions, {'cat-b': 0, 'cat-a': 1});
    },
  );

  testWidgets('collapse toggles the stored fold state for that category '
      'only', (tester) async {
    final setup = _setup();
    addTearDown(setup.container.dispose);
    addTearDown(setup.db.close);
    await _pump(tester, setup.container, _categories[0]);

    await _openMenu(tester);
    expect(find.text('Collapse category'), findsOneWidget);
    await tester.tap(find.text('Collapse category'));
    await tester.pumpAndSettle();

    expect(setup.container.read(collapsedCategoriesProvider), {'cat-a'});
  });
}
