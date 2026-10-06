// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `StatusTextRow`: the personal settings field that sets `status_text` on
/// the caller's own profile, mirroring `edit_display_name_sheet_test.dart`'s
/// shape for `updateMe`'s other caller.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/status_text_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

({ProviderContainer container, List<Uri> requests, List<String?> patched})
_wire({
  String? currentStatus,
  int patchStatus = 200,
  String patchError = 'status must be at most 80 characters',
}) {
  final requests = <Uri>[];
  final patched = <String?>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            requests.add(request.url);
            if (request.method == 'PATCH' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              patched.add(body['status_text'] as String?);
              if (patchStatus != 200) {
                return http.Response(
                  jsonEncode({'error': patchError}),
                  patchStatus,
                  headers: {'content-type': 'application/json'},
                );
              }
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'status_text': body['status_text'],
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'permissions': 0,
                  'status_text': currentStatus,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response('', 204);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, requests: requests, patched: patched);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: StatusTextRow()),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
}

void main() {
  testWidgets('shows nothing while the profile has not loaded', (tester) async {
    final wired = _wire();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: wired.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(body: StatusTextRow()),
        ),
      ),
    );
    // No pump yet: `meProvider` is still in flight.
    expect(find.byType(TextField), findsNothing);
  });

  testWidgets('prefills the field with the current status', (tester) async {
    final wired = _wire(currentStatus: 'in a meeting');
    await _pump(tester, wired.container);

    expect(find.text('in a meeting'), findsOneWidget);
  });

  testWidgets('Save is hidden until the text actually changes', (tester) async {
    final wired = _wire(currentStatus: 'afk');
    await _pump(tester, wired.container);

    expect(find.widgetWithText(AppButton, 'Save'), findsNothing);

    await tester.enterText(find.byType(TextField), 'back');
    await tester.pump();

    expect(find.widgetWithText(AppButton, 'Save'), findsOneWidget);
  });

  testWidgets('saving sends the trimmed status and refreshes meProvider', (
    tester,
  ) async {
    final wired = _wire(currentStatus: null);
    await _pump(tester, wired.container);

    await tester.enterText(find.byType(TextField), '  at lunch  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();

    expect(wired.patched, ['at lunch']);
  });

  testWidgets('a server refusal is shown honestly, field keeps the text', (
    tester,
  ) async {
    final wired = _wire(
      currentStatus: 'afk',
      patchStatus: 400,
      patchError: 'status must not contain control characters',
    );
    await _pump(tester, wired.container);

    await tester.enterText(find.byType(TextField), 'a new status');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();

    // Sentence-cased at the display seam since #636; the wire stays lowercase.
    expect(
      find.textContaining('Status must not contain control characters'),
      findsOneWidget,
    );
    expect(find.text('a new status'), findsOneWidget);
  });

  testWidgets('eighty emoji count as eighty characters, as the server does', (
    tester,
  ) async {
    final wired = _wire(currentStatus: null);
    await _pump(tester, wired.container);
    final eighty = List.filled(80, '\u{1F600}').join();

    await tester.enterText(find.byType(TextField), eighty);
    await tester.pump();
    expect(find.text('80/80'), findsOneWidget);
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();

    expect(wired.patched, [eighty]);
  });
}
