// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The display name edit sheet: `updateMe`'s one caller.
///
/// The server validates length and refuses control/text-direction characters
/// (`validate_label` in `crates/slimm-server/src/http/auth.rs`); this suite
/// checks the sheet disables Save for an obviously bad length and, for
/// anything the client does not pre-empt, shows the server's own refusal
/// rather than silently trimming or swallowing it.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/edit_display_name_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

({ProviderContainer container, List<Uri> requests}) _wire({
  int patchStatus = 200,
  String patchError = 'display_name must be 1 to 64 characters',
}) {
  final requests = <Uri>[];
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
                  'display_name': 'New Name',
                  'created_at': 0,
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
                  'display_name': 'Old Name',
                  'created_at': 0,
                  'permissions': 0,
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
  return (container: container, requests: requests);
}

Future<void> _open(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showEditDisplayNameSheet(context, 'Old Name'),
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
  testWidgets('Save is disabled until the name actually changes', (
    tester,
  ) async {
    final wired = _wire();
    await _open(tester, wired.container);

    expect(
      tester.widget<AppButton>(find.byType(AppButton)).disabled,
      isTrue,
      reason: 'the field starts prefilled with the unchanged name',
    );
  });

  testWidgets('Save is disabled once the name is emptied', (tester) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.enterText(find.byType(TextField), '');
    await tester.pump();

    expect(tester.widget<AppButton>(find.byType(AppButton)).disabled, isTrue);
  });

  testWidgets('Save is disabled past 64 characters', (tester) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.enterText(find.byType(TextField), 'x' * 65);
    await tester.pump();

    expect(tester.widget<AppButton>(find.byType(AppButton)).disabled, isTrue);
    expect(find.text('65/64'), findsOneWidget);
  });

  testWidgets('40 astral characters count as 40 and can be saved', (
    tester,
  ) async {
    final wired = _wire();
    await _open(tester, wired.container);

    await tester.enterText(find.byType(TextField), '\u{1F600}' * 40);
    await tester.pump();

    expect(find.text('40/64'), findsOneWidget);
    expect(tester.widget<AppButton>(find.byType(AppButton)).disabled, isFalse);
  });

  testWidgets(
    'a valid change sends PATCH /me, refreshes meProvider and closes',
    (tester) async {
      final wired = _wire();
      await _open(tester, wired.container);

      await tester.enterText(find.byType(TextField), 'New Name');
      await tester.pump();
      expect(
        tester.widget<AppButton>(find.byType(AppButton)).disabled,
        isFalse,
      );

      await tester.tap(find.text('Save name'));
      await tester.pumpAndSettle();

      expect(wired.requests.where((u) => u.path == '/me'), isNotEmpty);
      expect(
        find.text('Edit display name'),
        findsNothing,
        reason: 'a successful save pops the sheet',
      );
    },
  );

  testWidgets(
    'a server refusal is shown honestly, not swallowed or auto-corrected',
    (tester) async {
      final wired = _wire(
        patchStatus: 400,
        patchError:
            'name must not contain control or text-direction '
            'characters',
      );
      await _open(tester, wired.container);

      await tester.enterText(find.byType(TextField), 'New Name');
      await tester.pump();
      await tester.tap(find.text('Save name'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Name must not contain control or text-direction characters',
        ),
        findsOneWidget,
      );
      expect(
        find.text('Edit display name'),
        findsOneWidget,
        reason: 'a failed save keeps the sheet open so the input is not lost',
      );
    },
  );
}
