// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign-in and create-account at phone and desktop width, light and dark, on
/// the compiled-in official server and on a self-hosted one.
///
/// The overflow assertion runs everywhere; PNGs are written only under
/// SLIMM_UI_SNAPSHOTS=1, like every sibling in this family.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'support/mock_app_version.dart';
import 'ui_snapshot_support.dart';

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1400, 880)};

Future<void> _pump(
  WidgetTester tester, {
  required Uri server,
  required bool creating,
  required Size size,
  required Brightness brightness,
}) async {
  final httpClient = MockClient(
    (request) async => request.url.path == '/version'
        ? http.Response(
            jsonEncode({'name': 'slim-m', 'version': '0.10.0', 'protocol': 1}),
            200,
            headers: const {'content-type': 'application/json'},
          )
        : http.Response('{}', 200),
  );
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => server),
      assumeNewAccountProvider.overrideWith((ref) => creating),
      probeApiProvider.overrideWithValue(
        (baseUrl) => api.SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
      ),
    ],
  );
  addTearDown(container.dispose);

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final dark = brightness == Brightness.dark;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(
            brightness,
            dark ? AppTokens.dark : AppTokens.light,
          ),
          home: const SignInScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  final servers = {
    'official': Uri.parse(officialServer),
    'selfhost': Uri.parse('https://chat.example'),
  };
  for (final server in servers.entries) {
    for (final creating in [false, true]) {
      for (final size in _sizes.entries) {
        for (final brightness in Brightness.values) {
          final name =
              'sign-in-${server.key}-${creating ? 'create' : 'signin'}-'
              '${size.key}-${brightness.name}';
          testWidgets(name, (tester) async {
            await _pump(
              tester,
              server: server.value,
              creating: creating,
              size: size.value,
              brightness: brightness,
            );
            await expectSettled(tester, name);
            await writeSnapshot(tester, name);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}
