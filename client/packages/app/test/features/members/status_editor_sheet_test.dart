// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Backlog item 128: a status editor reached by tapping your own avatar in
/// the sidebar. Under `kCompactWidth` the avatar menu still routes free-text
/// editing through this bottom sheet; `presence_status_field_test.dart`
/// covers the wide-window case, which per `docs/design/desktop-vs-mobile.md`
/// rule 2 types directly into the anchored menu instead of escalating to a
/// sheet. Drives it the way `space_menu_button_test.dart` drives its own
/// avatar-adjacent menu - tap the avatar, tap the item, drive the sheet -
/// and mirrors `status_text_row_test.dart`'s `PATCH /me` wiring, since both
/// ultimately call the same `SlimmApi.updateMe`.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/presence_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

({ProviderContainer container, List<String?> patched}) _wire({
  String? currentStatus,
  int patchStatus = 200,
  String patchError = 'status must be at most 80 characters',
}) {
  final patched = <String?>[];
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
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
        return http.Response('[]', 200);
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, patched: patched);
}

/// Under `kCompactWidth`, so the avatar opens the bottom sheet rather than
/// the anchored menu - the case this file covers.
Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(390, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(
          body: Align(
            alignment: Alignment.bottomLeft,
            child: SizedBox(width: 44, height: 44, child: PresenceMenuButton()),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// Opens the avatar sheet and taps "Set a status", landing on the editor.
Future<void> _openEditor(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Change your status'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Set a status'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the avatar sheet offers Set a status alongside the presence '
      'choices', (tester) async {
    final wired = _wire();
    await _pump(tester, wired.container);

    await tester.tap(find.bySemanticsLabel('Change your status'));
    await tester.pumpAndSettle();

    expect(find.text('Set a status'), findsOneWidget);
    expect(find.text('Online'), findsOneWidget);
    expect(find.text('Appear offline'), findsOneWidget);
  });

  testWidgets('the editor opens prefilled with the current status', (
    tester,
  ) async {
    final wired = _wire(currentStatus: 'in a meeting');
    await _pump(tester, wired.container);

    await _openEditor(tester);

    expect(find.text('in a meeting'), findsOneWidget);
  });

  testWidgets('Save sends the trimmed status and closes the editor', (
    tester,
  ) async {
    final wired = _wire(currentStatus: null);
    await _pump(tester, wired.container);

    await _openEditor(tester);
    await tester.enterText(find.byType(TextField), '  at lunch  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();

    expect(wired.patched, ['at lunch']);
    expect(find.text('Set a status'), findsNothing);
  });

  testWidgets('Clear sends an empty status and closes the editor', (
    tester,
  ) async {
    final wired = _wire(currentStatus: 'afk');
    await _pump(tester, wired.container);

    await _openEditor(tester);
    await tester.tap(find.widgetWithText(AppButton, 'Clear'));
    await tester.pumpAndSettle();

    expect(wired.patched, ['']);
    expect(find.text('Set a status'), findsNothing);
  });

  testWidgets('a server refusal is shown honestly and the editor stays open', (
    tester,
  ) async {
    final wired = _wire(
      currentStatus: 'afk',
      patchStatus: 400,
      patchError: 'status must not contain control characters',
    );
    await _pump(tester, wired.container);

    await _openEditor(tester);
    await tester.enterText(find.byType(TextField), 'a new status');
    await tester.pump();
    await tester.tap(find.widgetWithText(AppButton, 'Save'));
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Status must not contain control characters'),
      findsOneWidget,
    );
    expect(find.text('Set a status'), findsOneWidget);
  });
}
