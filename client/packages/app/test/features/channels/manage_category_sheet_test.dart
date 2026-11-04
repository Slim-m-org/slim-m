// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rename-category sheet: rename sends the PATCH and updates the store.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_data/data.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/channels/widgets/manage_category_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import '../../support/fake_api.dart';

ChannelCategoryRow _category() =>
    const ChannelCategoryRow(id: 'cat-1', name: 'Gaming', position: 0);

Future<({List<http.Request> requests, MessageStore store})> _pump(
  WidgetTester tester, {
  required http.Response Function(http.Request) handler,
  bool deleteInstead = false,
}) async {
  final requests = <http.Request>[];
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  await store.upsertCategory(
    const api.ChannelCategory(
      id: 'cat-1',
      name: 'Gaming',
      position: 0,
      createdAt: 0,
    ),
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sessionProvider.overrideWithValue(
          api.SessionStore(
            tokens: const api.TokenPair(
              userId: 'self',
              accessToken: 'a',
              refreshToken: 'r',
              accessExpiresAt: 0,
            ),
          ),
        ),
        storeProvider.overrideWith((ref) async => store),
        mockApiOverride((request) async {
          requests.add(request);
          return handler(request);
        }),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => deleteInstead
                    ? confirmAndDeleteCategory(context, ref, _category())
                    : showRenameCategorySheet(context, _category()),
                child: Text(deleteInstead ? 'delete' : 'open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  if (!deleteInstead) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  return (requests: requests, store: store);
}

void main() {
  testWidgets('rename sends a PATCH and upserts the store', (tester) async {
    final r = await _pump(
      tester,
      handler: (request) {
        if (request.method == 'PATCH' &&
            request.url.path == '/categories/cat-1') {
          return http.Response(
            jsonEncode({
              'id': 'cat-1',
              'name': 'Board games',
              'position': 0,
              'created_at': 0,
            }),
            200,
            headers: {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 404);
      },
    );

    await tester.enterText(find.byType(TextField), 'Board games');
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    final patch = r.requests.singleWhere((req) => req.method == 'PATCH');
    expect(jsonDecode(patch.body)['name'], 'Board games');
    final stored = await r.store.allCategories();
    expect(stored.single.name, 'Board games');
  });

  testWidgets('the menu path deletes after a confirmation', (tester) async {
    final r = await _pump(
      tester,
      handler: (request) => http.Response('', 204),
      deleteInstead: true,
    );
    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    expect(r.requests.any((req) => req.method == 'DELETE'), isFalse);

    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(
      r.requests.any(
        (req) => req.method == 'DELETE' && req.url.path == '/categories/cat-1',
      ),
      isTrue,
    );
    expect(await r.store.allCategories(), isEmpty);
  });

  testWidgets('the sheet is a pure rename with no delete', (tester) async {
    await _pump(tester, handler: (request) => http.Response('', 204));

    expect(find.text('Rename category'), findsOneWidget);
    expect(find.text('Delete category'), findsNothing);
    expect(find.text('DANGER ZONE'), findsNothing);
  });

  testWidgets('a failed rename shows an error and keeps the sheet open', (
    tester,
  ) async {
    await _pump(
      tester,
      handler: (request) => http.Response('{"error":"nope"}', 500),
    );

    await tester.enterText(find.byType(TextField), 'Board games');
    await tester.pump();
    await tester.tap(find.text('Save changes'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.text('Rename category'), findsOneWidget);
  });
}
