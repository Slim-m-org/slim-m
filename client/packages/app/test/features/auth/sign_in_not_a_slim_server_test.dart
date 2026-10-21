// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An address that answers without a slim-m `/version` (the web app's own port,
/// say) is named as such on the Server field, and "Wrong username or password"
/// stays for a real 401 from a real server.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/labeled_field.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';

const _noServer = 'No slim-m server at that address.';

http.Response _html(int status) => http.Response(
  '<!doctype html><title>app</title>',
  status,
  headers: const {'content-type': 'text/html'},
);

http.Response _json(Object body, int status) => http.Response(
  jsonEncode(body),
  status,
  headers: const {'content-type': 'application/json'},
);

Future<void> _signInAgainst(WidgetTester tester, http.Client client) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith(
        (ref) => Uri.parse('https://notes.example.test:8080'),
      ),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: client,
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const SignInScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  Finder field(String label) => find.descendant(
    of: find.widgetWithText(LabeledField, label),
    matching: find.byType(TextField),
  );
  await tester.enterText(field('Username'), 'alice');
  await tester.enterText(field('Password'), 'hunter2');
  final submit = find.widgetWithText(AppButton, 'Sign in');
  await tester.ensureVisible(submit);
  await tester.tap(submit);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a web page answering 200 is not a slim-m server', (
    tester,
  ) async {
    await _signInAgainst(tester, MockClient((_) async => _html(200)));

    expect(find.text(_noServer), findsOneWidget);
    expect(find.textContaining('refused'), findsNothing);
    expect(find.text('Wrong username or password.'), findsNothing);
  });

  testWidgets('a server answering 404 with no slim-m body is not one either', (
    tester,
  ) async {
    await _signInAgainst(tester, MockClient((_) async => _html(404)));

    expect(find.text(_noServer), findsOneWidget);
  });

  testWidgets('a real slim-m 401 still says wrong username or password', (
    tester,
  ) async {
    final client = MockClient((request) async {
      if (request.url.path == '/version') {
        return _json({
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
        }, 200);
      }
      return _json({'error': 'invalid credentials'}, 401);
    });

    await _signInAgainst(tester, client);

    expect(find.text('Wrong username or password.'), findsOneWidget);
    expect(find.text(_noServer), findsNothing);
  });

  testWidgets('a server that does not answer is not called a non-slim-m one', (
    tester,
  ) async {
    await _signInAgainst(
      tester,
      MockClient((_) async => throw http.ClientException('refused')),
    );

    expect(find.text(_noServer), findsNothing);
    expect(find.textContaining("didn't answer"), findsOneWidget);
  });
}
