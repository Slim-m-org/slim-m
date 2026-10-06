// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Invites pane's rows and its create form: a row's failure stays on its
/// own invite when the list shifts, and a zero use limit never reaches the
/// server.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/action_labels.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/invites_screen.dart';
import 'package:slimm_app/src/widgets/settings_entity_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _inv(String code) => jsonEncode({
  'code': code,
  'max_uses': null,
  'uses': 0,
  'expires_at': null,
  'created_at': 0,
  'revoked': false,
  'usable': true,
  'role_grant': null,
});

const _json = {'content-type': 'application/json'};

Future<void> _pump(
  WidgetTester tester,
  Future<http.Response> Function(http.Request) handler,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      myPermissionsProvider.overrideWithValue(Perm.createInvite),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient(handler),
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
        home: const InvitesScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'a revoke error stays on its own invite when a new one is added',
    (tester) async {
      var created = false;
      await _pump(tester, (request) async {
        if (request.method == 'GET' && request.url.path == '/invites') {
          final list = created
              ? [_inv('code-c'), _inv('code-a'), _inv('code-b')]
              : [_inv('code-a'), _inv('code-b')];
          return http.Response('[${list.join(',')}]', 200, headers: _json);
        }
        if (request.method == 'DELETE') {
          return http.Response(
            jsonEncode({'error': 'boom'}),
            500,
            headers: _json,
          );
        }
        if (request.method == 'POST') {
          created = true;
          return http.Response(_inv('code-c'), 200, headers: _json);
        }
        return http.Response('{}', 404, headers: _json);
      });

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(SettingsEntityRow, 'code-b'),
          matching: find.byIcon(AppIcons.revoke),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Revoke'));
      await tester.pumpAndSettle();
      Finder errorIn(String code) => find.descendant(
        of: find.widgetWithText(SettingsEntityRow, code),
        matching: find.byType(AppErrorState),
      );
      expect(errorIn('code-b'), findsOneWidget, reason: 'precondition');

      await tester.tap(find.text(ActionLabels.createInvite));
      await tester.pumpAndSettle();
      expect(find.text('code-c'), findsWidgets);

      expect(
        errorIn('code-a'),
        findsNothing,
        reason: 'code-a never failed, but the unkeyed row State moved to it',
      );
      expect(errorIn('code-b'), findsOneWidget);
    },
  );

  testWidgets('a use limit of zero is refused inline and never sent', (
    tester,
  ) async {
    final posts = <String>[];
    await _pump(tester, (request) async {
      if (request.method == 'POST') posts.add(request.body);
      return http.Response('[]', 200, headers: _json);
    });

    await tester.enterText(find.byType(TextField).first, '0');
    await tester.pump();
    await tester.tap(find.text(ActionLabels.createInvite));
    await tester.pumpAndSettle();

    expect(posts, isEmpty);
    expect(find.textContaining('leave blank for unlimited'), findsOneWidget);
  });
}
