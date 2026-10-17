// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// On a wide window the avatar menu's free-text status editor is an inline
/// `AppInput` in the anchored `AppMenu` itself, not a dialog hop through
/// `status_editor_sheet.dart` - `docs/design/desktop-vs-mobile.md` rule 2:
/// a control that stays on screen (status) is a dropdown anchored to the
/// control, the same body a context menu uses, everywhere there is room for
/// one. `status_editor_sheet_test.dart` covers the unchanged compact-width
/// sheet. This also covers the clear affordance built into that field: a
/// small "Clear status" icon button trailing the input, replacing the
/// separate always-there-when-set menu row this field used to sit above.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/presence_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

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
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
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
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, patched: patched);
}

/// Wide, so the avatar opens the anchored `AppMenu` rather than the sheet -
/// the case this file covers. Taller than the default 600 so the menu
/// opening upward off the avatar has room.
Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(800, 1400);
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

Future<void> _openMenu(WidgetTester tester) async {
  await tester.tap(find.bySemanticsLabel('Change your status'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the menu offers an inline field instead of Set a status', (
    tester,
  ) async {
    final wired = _wire();
    await _pump(tester, wired.container);

    await _openMenu(tester);

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('What are you up to?'), findsOneWidget);
    expect(
      find.text('Set a status'),
      findsNothing,
      reason: 'a wide window has room to edit in place, not to open a dialog',
    );
  });

  testWidgets('the inline field opens prefilled with the current status', (
    tester,
  ) async {
    final wired = _wire(currentStatus: 'in a meeting');
    await _pump(tester, wired.container);

    await _openMenu(tester);

    expect(find.text('in a meeting'), findsOneWidget);
  });

  testWidgets('the clear affordance is absent when no status is set', (
    tester,
  ) async {
    final wired = _wire(currentStatus: null);
    await _pump(tester, wired.container);

    await _openMenu(tester);

    expect(find.bySemanticsLabel('Clear status'), findsNothing);
  });

  testWidgets('the clear affordance is absent for an empty (not null) status', (
    tester,
  ) async {
    final wired = _wire(currentStatus: '');
    await _pump(tester, wired.container);

    await _openMenu(tester);

    expect(find.bySemanticsLabel('Clear status'), findsNothing);
  });

  testWidgets('the clear affordance appears once a status is set', (
    tester,
  ) async {
    final wired = _wire(currentStatus: 'afk');
    await _pump(tester, wired.container);

    await _openMenu(tester);

    expect(find.bySemanticsLabel('Clear status'), findsOneWidget);
  });

  testWidgets(
    'a separate Clear status menu row no longer exists beside the field',
    (tester) async {
      final wired = _wire(currentStatus: 'afk');
      await _pump(tester, wired.container);

      await _openMenu(tester);

      expect(find.text('Clear status'), findsNothing);
    },
  );

  testWidgets('typing into the field does not close the menu', (tester) async {
    final wired = _wire();
    await _pump(tester, wired.container);

    await _openMenu(tester);
    await tester.enterText(find.byType(TextField), 'at lunch');
    await tester.pump();

    expect(find.byType(AppMenu), findsOneWidget);
    expect(wired.patched, isEmpty);
  });

  testWidgets('pressing Enter sends the trimmed status and closes the menu', (
    tester,
  ) async {
    final wired = _wire();
    await _pump(tester, wired.container);

    await _openMenu(tester);
    await tester.enterText(find.byType(TextField), '  at lunch  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(wired.patched, ['at lunch']);
    expect(find.byType(AppMenu), findsNothing);
  });

  testWidgets(
    'the clear affordance sends an empty status in one tap and closes the '
    'menu',
    (tester) async {
      final wired = _wire(currentStatus: 'afk');
      await _pump(tester, wired.container);

      await _openMenu(tester);
      await tester.tap(find.bySemanticsLabel('Clear status'));
      await tester.pumpAndSettle();

      expect(wired.patched, ['']);
      expect(find.byType(AppMenu), findsNothing);
    },
  );

  testWidgets('a refused save is shown honestly and the menu stays open', (
    tester,
  ) async {
    final wired = _wire(
      currentStatus: 'afk',
      patchStatus: 400,
      patchError: 'status must not contain control characters',
    );
    await _pump(tester, wired.container);

    await _openMenu(tester);
    await tester.enterText(find.byType(TextField), 'a new status');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(
      find.textContaining('Status must not contain control characters'),
      findsOneWidget,
    );
    expect(find.byType(AppMenu), findsOneWidget);
  });

  testWidgets('a refused clear is shown honestly and the menu stays open', (
    tester,
  ) async {
    final wired = _wire(currentStatus: 'afk', patchStatus: 500);
    await _pump(tester, wired.container);

    await _openMenu(tester);
    await tester.tap(find.bySemanticsLabel('Clear status'));
    await tester.pumpAndSettle();

    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(AppMenu), findsOneWidget);
  });
}
