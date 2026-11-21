// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign-in and create-account at phone and desktop width, light and dark, on
/// the compiled-in official server and on a self-hosted one, plus the steps of
/// the one form: a first visit, the create step after the server finds no
/// account, a password mismatch there, and a refused password.
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
import 'package:slimm_app/src/features/auth/widgets/server_identity_confirmation.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../support/async_wait.dart';
import '../support/mid_flight_capture.dart';
import '../support/mock_app_version.dart';
import '../support/sign_in_steps.dart';
import '../ui_snapshot_support.dart';

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1400, 880)};

/// The states of the one form that a server with `username_check` leads to.
enum _Step { firstContact, noAccount, mismatch, wrongPassword }

Future<void> _pump(
  WidgetTester tester, {
  required Uri server,
  required Size size,
  required Brightness brightness,
  bool creating = false,
  _Step? step,
}) async {
  final httpClient = MockClient((request) async {
    const headers = {'content-type': 'application/json'};
    return switch (request.url.path) {
      '/version' => http.Response(
        jsonEncode({
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'capabilities': [if (step != null) usernameCheckCapability],
        }),
        200,
        headers: headers,
      ),
      '/auth/username/check' => http.Response(
        jsonEncode({'exists': step == _Step.wrongPassword}),
        200,
        headers: headers,
      ),
      '/auth/login' => http.Response(
        jsonEncode({'error': 'unauthorized'}),
        401,
        headers: headers,
      ),
      _ => http.Response('{}', 200),
    };
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => server),
      if (step == _Step.firstContact)
        firstContactServersProvider.overrideWith(
          (ref) => {identityHandleFor(server)},
        ),
      probeApiProvider.overrideWithValue(
        (baseUrl) => api.SlimmApi(baseUrl: baseUrl, httpClient: httpClient),
      ),
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: ref.watch(serverUrlProvider),
          session: ref.watch(sessionProvider),
          httpClient: httpClient,
        );
        ref.onDispose(client.close);
        return client;
      }),
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
  if (creating) await chooseCreateInstead(tester);
  if (step == null || step == _Step.firstContact) return;
  await submitUntilCreateStep(
    tester,
    username: 'dana',
    password: 'long enough pw',
  );
  if (step == _Step.mismatch) await confirmAndCreate(tester, 'long enough');
  await pumpFrames(tester, frames: 30);
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
    for (final step in _Step.values) {
      for (final size in _sizes.entries) {
        for (final brightness in Brightness.values) {
          final name =
              'sign-in-${server.key}-${step.name}-'
              '${size.key}-${brightness.name}';
          testWidgets(name, (tester) async {
            await _pump(
              tester,
              server: server.value,
              step: step,
              size: size.value,
              brightness: brightness,
            );
            _expectStep(step);
            await expectSettled(tester, name);
            await writeSnapshot(tester, name);
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }
}

/// Fails a capture that did not reach the state its name promises.
void _expectStep(_Step step) {
  final (title, text) = switch (step) {
    _Step.firstContact => (
      'Sign in or create an account',
      'Create an account instead',
    ),
    _Step.noAccount => ('Create an account', 'There is no account named dana'),
    _Step.mismatch => ('Create an account', 'The passwords do not match.'),
    _Step.wrongPassword => ('Welcome back', 'Wrong password for dana.'),
  };
  expect(find.text(title), findsOneWidget);
  expect(find.textContaining(text), findsOneWidget);
}
