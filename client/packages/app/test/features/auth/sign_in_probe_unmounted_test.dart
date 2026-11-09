// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Leaving the sign-in screen while the server probe is still in flight must
/// not touch `ref` once the answer arrives.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/mock_app_version.dart';

void main() {
  setUpAll(mockAppVersion);

  testWidgets('a probe answering after the screen is gone is dropped quietly', (
    tester,
  ) async {
    final answer = Completer<http.Response>();
    final client = MockClient((_) => answer.future);
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        serverUrlProvider.overrideWith((ref) => Uri.parse('https://chat.test')),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
        ),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const SignInScreen(),
        ),
      ),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    answer.complete(
      http.Response(
        jsonEncode({'name': 'slim-m', 'version': '0.10.0', 'protocol': 1}),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
