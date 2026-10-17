// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail footer's second line used to always be the generic presence
/// word; `Me.statusText`, set from the same status menu right above this row,
/// was never surfaced anywhere here. It now joins the presence word
/// ("online · swagging"), the same pair the member pane shows for everyone
/// else (design review note 7).
///
/// The generic word is the caller's own presence, `online` for a connected
/// client that has not been told otherwise. Nothing on this line reports the
/// socket.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_sync.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container({String? statusText}) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    syncControllerProvider.overrideWith(StubSyncController.new),
    apiProvider.overrideWith((ref) {
      final client = api.SlimmApi(
        baseUrl: Uri.parse('http://localhost:8080'),
        session: ref.watch(sessionProvider),
        httpClient: MockClient((request) async {
          if (request.url.path == '/me') {
            return http.Response(
              jsonEncode({
                'id': 'self',
                'username': 'self',
                'display_name': 'Self',
                'created_at': 0,
                'permissions': 0,
                if (statusText != null) 'status_text': statusText,
              }),
              200,
              headers: {'content-type': 'application/json'},
            );
          }
          return http.Response(
            '{}',
            404,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      ref.onDispose(client.close);
      return client;
    }),
  ],
);

Future<void> _pumpFooter(
  WidgetTester tester,
  ProviderContainer container,
) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(alignment: Alignment.bottomLeft, child: RailUserFooter()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a typed status joins the presence word rather than replacing '
      'it', (tester) async {
    final container = _container(statusText: 'heads down, back in an hour');
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('online · heads down, back in an hour'), findsOneWidget);
  });

  testWidgets('with no status text set, the generic word still shows', (
    tester,
  ) async {
    final container = _container();
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('online'), findsOneWidget);
  });

  testWidgets('a status cleared back to empty falls back to the generic word', (
    tester,
  ) async {
    final container = _container(statusText: '');
    addTearDown(container.dispose);
    await _pumpFooter(tester, container);

    expect(find.text('online'), findsOneWidget);
  });
}
