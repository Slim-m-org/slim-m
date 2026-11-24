// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A token that holds ADMINISTRATOR asks its issuer for their password; an ordinary one does not.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/settings/screens/admin/bots_screen.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/bot_menu.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _bot(int permissions) => {
  'user_id': 'bot-helper',
  'username': 'helper',
  'display_name': 'helper',
  'created_at': 0,
  'token_name': 'Helper',
  'role_id': 'role-helper',
  'permissions': permissions,
  'online': false,
};

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// The bodies of every POST to a bot token, in order.
Future<List<Map<String, dynamic>>> _pump(
  WidgetTester tester, {
  required int permissions,
  String? wrongPasswordOf,
}) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final bodies = <Map<String, dynamic>>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      myPermissionsProvider.overrideWithValue(Perm.all),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride(
        withSpaceSettings((request) async {
          final path = request.url.path;
          if (request.method == 'GET' && path == '/bots') {
            return _json([_bot(permissions)]);
          }
          if (request.method == 'POST' && path.endsWith('/token')) {
            final body = request.body.isEmpty
                ? <String, dynamic>{}
                : jsonDecode(request.body) as Map<String, dynamic>;
            bodies.add(body);
            if (body['password'] == null && permissions.hasPermission(1)) {
              return _json({'error': 'your password is required'}, 400);
            }
            if (wrongPasswordOf != null &&
                body['password'] == wrongPasswordOf) {
              return _json({'error': 'that password is not correct'}, 403);
            }
            return _json({'bot': _bot(permissions), 'token': 'slimbot_new'});
          }
          if (request.method == 'PATCH' && path.endsWith('/permissions')) {
            bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
            return _json(_bot(Perm.administrator));
          }
          return http.Response('[]', 200);
        }),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const BotsScreen(),
      ),
    ),
  );
  await _settle(tester);
  return bodies;
}

Future<void> _reissue(WidgetTester tester) async {
  await openBotMenu(tester);
  await tester.tap(botMenuItem('Re-issue token'));
  await _settle(tester);
  await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
  await _settle(tester);
}

Finder get _passwordField => find.bySemanticsLabel('Your password');
Finder get _passwordInput => find.widgetWithText(TextField, 'Your password');

void main() {
  testWidgets('re-issuing an Administrator bot asks for the password first', (
    tester,
  ) async {
    final bodies = await _pump(tester, permissions: Perm.administrator);
    await _reissue(tester);

    expect(_passwordField, findsOneWidget);
    expect(bodies, isEmpty);

    await tester.enterText(_passwordInput, 'hunter2');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await _settle(tester);

    expect(bodies, [
      {'password': 'hunter2'},
    ]);
    expect(find.textContaining('slimbot_new'), findsOneWidget);
  });

  testWidgets('a wrong password shows under the field and keeps the prompt', (
    tester,
  ) async {
    final bodies = await _pump(
      tester,
      permissions: Perm.administrator,
      wrongPasswordOf: 'nope',
    );
    await _reissue(tester);
    await tester.enterText(_passwordInput, 'nope');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Re-issue').last);
    await _settle(tester);

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(_passwordField, findsOneWidget);
    expect(bodies, [
      {'password': 'nope'},
    ]);
  });

  testWidgets('re-issuing an ordinary bot never asks for a password', (
    tester,
  ) async {
    final bodies = await _pump(tester, permissions: Perm.sendMessages);
    await _reissue(tester);

    expect(_passwordField, findsNothing);
    expect(bodies, [<String, dynamic>{}]);
    expect(find.textContaining('slimbot_new'), findsOneWidget);
  });

  testWidgets('saving an Administrator grant asks for the password first', (
    tester,
  ) async {
    final bodies = await _pump(tester, permissions: Perm.sendMessages);
    await openBotMenu(tester);
    await tester.tap(botMenuItem('Permissions'));
    await _settle(tester);
    final admin = tester
        .widgetList<AppToggle>(find.byWidgetPredicate((w) => w is AppToggle))
        .firstWhere((t) => t.semanticLabel == 'Administrator');
    admin.onChanged!(true);
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await _settle(tester);

    expect(_passwordField, findsOneWidget);
    expect(bodies, isEmpty);

    await tester.enterText(_passwordInput, 'hunter2');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save changes').last);
    await _settle(tester);

    expect(bodies.single['password'], 'hunter2');
    expect(bodies.single['permissions'], isA<int>());
  });

  testWidgets('saving an ordinary grant sends no password', (tester) async {
    final bodies = await _pump(tester, permissions: 0);
    await openBotMenu(tester);
    await tester.tap(botMenuItem('Permissions'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await _settle(tester);

    expect(_passwordField, findsNothing);
    expect(bodies.single.containsKey('password'), isFalse);
  });
}
