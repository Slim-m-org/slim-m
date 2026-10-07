// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bot permissions sheet closes through the design system's icon button
/// and says plainly, in place, when saving fails.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/bots_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

final _bot = Bot.fromJson(const {
  'user_id': 'bot-helper',
  'username': 'helper',
  'display_name': 'helper',
  'created_at': 0,
  'token_name': 'Helper',
  'token_last_used_at': null,
  'role_id': 'role-helper',
  'permissions': 0,
});

Future<void> _openSheet(
  WidgetTester tester,
  http.Response Function(http.Request) handler,
) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
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
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showBotPermissionsSheet(context, _bot),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the close control is the design system icon button and closes '
      'the sheet', (tester) async {
    await _openSheet(tester, (_) => http.Response('{}', 200));

    final close = find.byWidgetPredicate(
      (w) => w is AppIconButton && w.semanticLabel == 'Close',
    );
    expect(close, findsOneWidget);
    await tester.tap(close);
    await tester.pumpAndSettle();

    expect(find.text("helper's permissions"), findsNothing);
  });

  testWidgets('a failed save names what failed, keeps the sheet open and lets '
      'the operator try again', (tester) async {
    await _openSheet(tester, (_) => http.Response('down', 500));

    await tester.tap(find.widgetWithText(AppButton, 'Save changes'));
    await tester.pumpAndSettle();

    expect(find.textContaining("save helper's permissions"), findsOneWidget);
    expect(find.text("helper's permissions"), findsOneWidget);
    expect(find.widgetWithText(AppButton, 'Save changes'), findsOneWidget);
  });
}
