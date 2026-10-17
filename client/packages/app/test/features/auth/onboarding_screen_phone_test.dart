// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// How the onboarding screen's two modals present at phone width.
///
/// Both used to be bare Material dialogs that stayed a fixed-size card on a
/// phone, unlike every other modal in this app, which collapses to a bottom
/// sheet. These pin that they go through `showAppSheet` and so collapse.
///
/// The identity-pinning flow lives in onboarding_screen_test.dart, and
/// userinfo stripping in onboarding_screen_userinfo_test.dart.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _phone = Size(360, 800);

const _version = {'name': 'slim-m', 'version': '0.6.0', 'protocol': 1};

Future<void> _pumpAtPhoneWidth(WidgetTester tester) async {
  tester.view.physicalSize = _phone;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final httpClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode(_version),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: OnboardingScreen(onServerChosen: (server, invite) {}),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'the manual server dialog collapses to a bottom sheet, like every '
    'other modal in the app, rather than staying a fixed-size dialog',
    (tester) async {
      await _pumpAtPhoneWidth(tester);
      await tester.tap(find.text('Connect to a Space'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );

  testWidgets(
    'the invite dialog collapses to a bottom sheet at phone width too',
    (tester) async {
      await _pumpAtPhoneWidth(tester);
      await tester.tap(find.text('I have an invite'));
      await tester.pumpAndSettle();

      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(BottomSheet), findsOneWidget);
    },
  );
}
