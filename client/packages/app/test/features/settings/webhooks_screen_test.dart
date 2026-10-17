// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The webhooks pane: rotating one reveals its new URL once, and the list says
/// how long ago each webhook last delivered.
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/settings/screens/admin/webhooks_screen.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _webhookJson({int? lastDeliveryAt}) => jsonEncode({
  'id': 'wh-1',
  'channel_id': 'chan-1',
  'label': 'sonarr',
  'created_at': 0,
  'last_delivery_at': lastDeliveryAt,
  'created_by_display_name': 'root',
});

Future<void> _pump(
  WidgetTester tester,
  http.Response Function(http.Request) handler, {
  MessageStore? store,
  double width = 800,
}) async {
  tester.view.physicalSize = Size(width, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      if (store != null) storeProvider.overrideWith((ref) async => store),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const WebhooksScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

const _json = {'content-type': 'application/json'};

void main() {
  test('the last-delivery label reads as a recency, not a bare fact', () {
    final now = DateTime.fromMillisecondsSinceEpoch(10 * 24 * 3600 * 1000);
    int ago(Duration d) => now.subtract(d).millisecondsSinceEpoch;
    expect(
      webhookDeliveryLabel(ago(const Duration(seconds: 5)), now),
      'Last delivered just now',
    );
    expect(
      webhookDeliveryLabel(ago(const Duration(minutes: 7)), now),
      'Last delivered 7m ago',
    );
    expect(
      webhookDeliveryLabel(ago(const Duration(hours: 3)), now),
      'Last delivered 3h ago',
    );
    expect(
      webhookDeliveryLabel(ago(const Duration(days: 4)), now),
      'Last delivered 4d ago',
    );
  });

  testWidgets('rotating posts to the rotate route and reveals the new URL', (
    tester,
  ) async {
    final posted = <String>[];
    await _pump(tester, (request) {
      if (request.method == 'GET' && request.url.path == '/webhooks') {
        return http.Response('[${_webhookJson()}]', 200, headers: _json);
      }
      if (request.method == 'POST') {
        posted.add(request.url.path);
        return http.Response(
          jsonEncode({
            'webhook': jsonDecode(_webhookJson()),
            'delivery_path': '/webhooks/wh-1/fresh-token',
          }),
          200,
          headers: _json,
        );
      }
      return http.Response('{}', 200);
    });

    expect(find.textContaining('Never delivered yet.'), findsOneWidget);

    await tester.tap(find.bySemanticsLabel('Rotate sonarr'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Rotate').last);
    await tester.pumpAndSettle();

    expect(posted, ['/webhooks/wh-1/rotate']);
    expect(
      find.text('http://localhost:8080/webhooks/wh-1/fresh-token'),
      findsOneWidget,
    );
  });

  Future<MessageStore> channelStore() async {
    final db = SlimmDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final store = MessageStore(db);
    await store.upsertChannels([
      const Channel(id: 'chan-1', name: 'alerts', kind: 'text', createdAt: 0),
    ]);
    return store;
  }

  testWidgets('creating a webhook sends the chosen channel and label', (
    tester,
  ) async {
    Map<String, dynamic>? body;
    final store = await channelStore();
    await _pump(tester, (request) {
      if (request.method == 'POST' && request.url.path == '/webhooks') {
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'webhook': jsonDecode(_webhookJson()),
            'delivery_path': '/webhooks/wh-1/first-token',
          }),
          201,
          headers: _json,
        );
      }
      return http.Response('[]', 200, headers: _json);
    }, store: store);

    await tester.tap(find.text('Choose a channel'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('alerts'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppButton, 'alerts'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'sonarr');
    await tester.tap(find.widgetWithText(AppButton, 'Create webhook'));
    await tester.pumpAndSettle();

    expect(body, {'channel_id': 'chan-1', 'label': 'sonarr'});
    expect(
      find.text('http://localhost:8080/webhooks/wh-1/first-token'),
      findsOneWidget,
    );
    await tester.tap(find.widgetWithText(AppButton, 'Done'));
    await tester.pumpAndSettle();
    expect(find.textContaining('first-token'), findsNothing);
  });

  testWidgets('a webhook needs a channel and a label before it is created', (
    tester,
  ) async {
    var posted = false;
    await _pump(tester, (request) {
      if (request.method == 'POST') posted = true;
      return http.Response('[]', 200, headers: _json);
    });
    await tester.enterText(find.byType(TextField).first, 'sonarr');
    await tester.tap(find.widgetWithText(AppButton, 'Create webhook'));
    await tester.pumpAndSettle();
    expect(posted, isFalse);
  });

  testWidgets('renaming sends the new label', (tester) async {
    Map<String, dynamic>? body;
    String? method;
    await _pump(tester, (request) {
      if (request.url.path == '/webhooks/wh-1') {
        method = request.method;
        body = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(_webhookJson(), 200, headers: _json);
      }
      return http.Response('[${_webhookJson()}]', 200, headers: _json);
    });

    await tester.tap(find.bySemanticsLabel('Rename sonarr'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'radarr');
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await tester.pumpAndSettle();

    expect(method, 'PATCH');
    expect(body, {'label': 'radarr'});
    expect(find.text('Rename sonarr'), findsNothing);
  });

  testWidgets('revoking asks first, then posts to the revoke route', (
    tester,
  ) async {
    final posted = <String>[];
    await _pump(tester, (request) {
      if (request.method == 'POST') {
        posted.add(request.url.path);
        return http.Response('', 204);
      }
      return http.Response('[${_webhookJson()}]', 200, headers: _json);
    });

    await tester.tap(find.bySemanticsLabel('Revoke sonarr'));
    await tester.pumpAndSettle();
    expect(find.text('Revoke sonarr?'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(posted, isEmpty);

    await tester.tap(find.bySemanticsLabel('Revoke sonarr'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Revoke').last);
    await tester.pumpAndSettle();
    expect(posted, ['/webhooks/wh-1/revoke']);
  });

  testWidgets('a failed revoke stays on its row as a persistent error', (
    tester,
  ) async {
    await _pump(tester, (request) {
      if (request.method == 'POST') return http.Response('down', 500);
      return http.Response('[${_webhookJson()}]', 200, headers: _json);
    });
    await tester.tap(find.bySemanticsLabel('Revoke sonarr'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Revoke').last);
    await tester.pumpAndSettle();
    expect(find.textContaining('revoke sonarr'), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('with no webhooks the list says so', (tester) async {
    await _pump(tester, (request) => http.Response('[]', 200, headers: _json));
    expect(find.text('No webhooks yet.'), findsOneWidget);
  });

  testWidgets('a webhook row fits a phone with its three actions', (
    tester,
  ) async {
    await _pump(tester, (request) {
      return http.Response('[${_webhookJson()}]', 200, headers: _json);
    }, width: 360);
    expect(tester.takeException(), isNull);
    expect(find.bySemanticsLabel('Rotate sonarr'), findsOneWidget);
  });
}
