// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The welcome message section: off by default, needs a channel to turn on,
/// an empty message means the default, and it saves the whole form in one PATCH.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/widgets/welcome_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

const _tokens = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

class _Server {
  final patches = <Map<String, dynamic>>[];

  MockClient get client => MockClient((request) async {
    switch ((request.method, request.url.path)) {
      case ('GET', '/space/settings'):
        return _json({'join_policy': 'invite'});
      case ('PATCH', '/space/settings'):
        patches.add(jsonDecode(request.body) as Map<String, dynamic>);
        return _json({'join_policy': 'invite'});
      case ('GET', '/channels'):
        return _json([
          {
            'id': 'c-hello',
            'name': 'hello',
            'kind': 'text',
            'position': 0,
            'created_at': 1,
          },
          {
            'id': 'c-voice',
            'name': 'hangout',
            'kind': 'voice',
            'position': 1,
            'created_at': 1,
          },
        ]);
    }
    return http.Response('{}', 404);
  });
}

final _toggle = find.byWidgetPredicate((w) => w is AppToggle);

Future<void> _pump(WidgetTester tester, _Server server) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: server.client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: SingleChildScrollView(child: WelcomeSection()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('turning it on needs a channel', (tester) async {
    final server = _Server();
    await _pump(tester, server);

    await tester.tap(_toggle);
    await pumpFrames(tester);
    await tester.tap(find.text('Save'));
    await pumpFrames(tester);

    expect(find.text('Pick a channel to turn this on.'), findsOneWidget);
    expect(server.patches, isEmpty);
  });

  testWidgets('an empty message turns it on with the default welcome', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);
    final hint = tester.widget<AppInput>(
      find.byWidgetPredicate((w) => w is AppInput),
    );
    expect(hint.placeholder, kDefaultWelcomeMessage);

    await tester.tap(_toggle);
    await pumpFrames(tester);
    await tester.tap(find.text('Welcome channel'));
    await pumpFrames(tester);
    await tester.tap(find.text('#hello'));
    await pumpFrames(tester);
    await tester.tap(find.text('Save'));
    await pumpFrames(tester);

    expect(find.textContaining('Pick a channel'), findsNothing);
    expect(server.patches.single, {
      'welcome_enabled': true,
      'welcome_channel_id': 'c-hello',
      'welcome_message': '',
    });
    expect(find.text('0/${api.InputLimits.welcomeMessage}'), findsOneWidget);
  });

  testWidgets('saving sends the toggle, the text channel and the message', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);

    await tester.tap(find.byType(AppToggle));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Welcome channel'));
    await tester.pumpAndSettle();
    expect(find.text('#hangout'), findsNothing);
    await tester.tap(find.text('#hello'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  Hi {user}!  ');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(server.patches.single, {
      'welcome_enabled': true,
      'welcome_channel_id': 'c-hello',
      'welcome_message': 'Hi {user}!',
    });
  });
}
