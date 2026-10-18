// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The member pane sat on "Could not load members." after the server came
/// back, until Retry was pressed, while every other surface recovered on
/// reconnect. Reaching live again after an outage reloads the roster.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(jsonEncode(body), 200);

void main() {
  testWidgets('the roster reloads by itself once the connection is back', (
    tester,
  ) async {
    var serverUp = false;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        mockApiOverride((request) async {
          final path = request.url.path;
          if (!serverUp) throw http.ClientException('connection refused');
          if (path == '/me') {
            return _json({
              'id': 'self',
              'username': 'self',
              'display_name': 'Self',
              'created_at': 0,
              'permissions': 0,
            });
          }
          if (path == '/presence') return _json(<Object>[]);
          return _json([
            {
              'id': '1',
              'username': 'priya',
              'display_name': 'Priya',
              'created_at': 0,
            },
          ]);
        }),
      ],
    );
    addTearDown(container.dispose);
    final failed = container.read(hasFailedSinceLiveProvider.notifier);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Could not load members.'), findsOneWidget);

    failed.state = true;
    await tester.pumpAndSettle();
    serverUp = true;
    failed.state = false;
    await tester.pumpAndSettle();

    expect(find.text('Could not load members.'), findsNothing);
    expect(find.text('Priya'), findsOneWidget);
  });
}
