// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The header menu's delete and move-up/down run after their menu has closed,
/// so a refusal has only a SnackBar to land in. The happy paths are covered by
/// `manage_category_sheet_test.dart`; this pins the failures.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/manage_category_sheet.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';

const _general = ChannelCategoryRow(id: 'cat-a', name: 'General', position: 0);
const _voice = ChannelCategoryRow(id: 'cat-b', name: 'Voice', position: 1);

Future<({ProviderContainer container, MessageStore store})> _pump(
  WidgetTester tester, {
  required Widget Function(BuildContext, WidgetRef) button,
}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  addTearDown(db.close);
  final store = MessageStore(db);
  for (final c in const [_general, _voice]) {
    await store.upsertCategory(
      api.ChannelCategory(
        id: c.id,
        name: c.name,
        position: c.position,
        createdAt: 0,
      ),
    );
  }
  final container = ProviderContainer(
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
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(
            (request) async => http.Response('{"error":"nope"}', 500),
          ),
        );
        ref.onDispose(client.close);
        return client;
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
          body: Consumer(
            builder: (context, ref, _) => Center(child: button(context, ref)),
          ),
        ),
      ),
    ),
  );
  return (container: container, store: store);
}

void main() {
  testWidgets('a refused delete is reported and the category stays', (
    tester,
  ) async {
    final r = await _pump(
      tester,
      button: (context, ref) => ElevatedButton(
        onPressed: () => confirmAndDeleteCategory(context, ref, _general),
        child: const Text('delete'),
      ),
    );

    await tester.tap(find.text('delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(
      find.textContaining('Could not delete the category'),
      findsOneWidget,
    );
    expect(await r.store.allCategories(), hasLength(2));
  });

  testWidgets('a refused move is reported and the failure is dismissed', (
    tester,
  ) async {
    final r = await _pump(
      tester,
      button: (context, ref) => ElevatedButton(
        onPressed: () =>
            moveCategoryAndReport(context, ref, [_general, _voice], _voice, -1),
        child: const Text('move'),
      ),
    );

    await tester.tap(find.text('move'));
    await tester.pumpAndSettle();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('Could not reorder categories'), findsOneWidget);
    expect(
      r.container.read(categoryOrderControllerProvider).error,
      isNull,
      reason:
          'the snackbar carries it, so the controller is not left holding it',
    );
  });
}
