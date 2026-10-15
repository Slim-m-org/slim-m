// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The sign-in button's busy state: the label cross-fades to a spinner
/// through an [AnimatedSwitcher] rather than swapping in one frame, matching
/// every other loading transition in the app.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';

/// Pumps [SignInScreen] whose `/auth/login` hangs on [gate] - long enough for
/// a test to inspect the button mid-submit - then answers with a refusal, no
/// success path needed for what this file checks.
Future<void> _pump(
  WidgetTester tester,
  Completer<void> gate, {
  bool reduceMotion = false,
}) async {
  final httpClient = MockClient((request) async {
    if (request.method == 'POST' && request.url.path == '/auth/login') {
      await gate.future;
      return http.Response('{"error":"wrong password"}', 401);
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
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
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: const SignInScreen(),
        ),
      ),
    ),
  );
  await tester.pump();

  await tester.enterText(find.byType(TextField).at(1), 'alice');
  await tester.enterText(find.byType(TextField).at(2), 'hunter2');
  await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
}

void main() {
  setUpAll(mockAppVersion);

  testWidgets(
    'submitting cross-fades the label to a spinner rather than snapping',
    (tester) async {
      final gate = Completer<void>();
      await _pump(tester, gate);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));

      final button = find.byType(AppButton);
      expect(
        find.descendant(
          of: button,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
        reason: 'the incoming spinner has set off',
      );
      expect(
        find.descendant(of: button, matching: find.text('Sign in')),
        findsOneWidget,
        reason: 'mid cross-fade the outgoing label is still painting too',
      );

      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'settled, only the spinner remains - the label is not left behind',
    (tester) async {
      final gate = Completer<void>();
      await _pump(tester, gate);
      await tester.pump();
      // Not pumpAndSettle: the spinner's own indeterminate ticker never settles.
      await tester.pump(const Duration(milliseconds: 200));

      final button = find.byType(AppButton);
      expect(
        _labelOpacity(tester, button),
        0,
        reason: 'the label keeps its space, so the button never resizes',
      );
      expect(
        find.descendant(
          of: button,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );

      gate.complete();
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'reduce motion swaps the label for the spinner with no cross-fade at all',
    (tester) async {
      final gate = Completer<void>();
      await _pump(tester, gate, reduceMotion: true);
      await tester.pump();

      final button = find.byType(AppButton);
      expect(
        find.descendant(
          of: button,
          matching: find.byType(CircularProgressIndicator),
        ),
        findsOneWidget,
      );
      expect(
        _labelOpacity(tester, button),
        0,
        reason:
            'reduce motion must land in one frame, never carrying the '
            'outgoing label along for a beat',
      );

      gate.complete();
      await tester.pumpAndSettle();
    },
  );
}

/// How opaque the button's label is painted; it stays laid out while busy.
double _labelOpacity(WidgetTester tester, Finder button) {
  final label = find.descendant(of: button, matching: find.text('Sign in'));
  final fade = find.ancestor(of: label, matching: find.byType(FadeTransition));
  return tester.widget<FadeTransition>(fade.first).opacity.value;
}
