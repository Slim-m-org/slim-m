// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Connect to a Space: the address is taken as people write it, Continue
/// shows it is waiting, and an error appears on the first press without
/// resizing the dialog.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

Future<void> _pump(
  WidgetTester tester, {
  required void Function(Uri) onChosen,
  Future<void>? answerGate,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final client = MockClient((request) async {
    await answerGate;
    return http.Response(
      jsonEncode({'name': 'slim-m', 'version': '0.6.0', 'protocol': 1}),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: OnboardingScreen(
          onServerChosen: (server, invite) => onChosen(server),
        ),
      ),
    ),
  );
  await pumpFrames(tester, frames: 30);
  await tester.tap(find.text('Connect to a Space'));
  await pumpFrames(tester, frames: 30);
}

Finder _addressField() => find.byWidgetPredicate(
  (w) => w is AppInput && w.semanticLabel == 'Server address',
);

Future<void> _submit(WidgetTester tester, String address) async {
  await tester.enterText(_addressField(), address);
  await tester.tap(find.text('Continue'));
}

void main() {
  testWidgets('a bare host connects over https', (tester) async {
    Uri? chosen;
    await _pump(tester, onChosen: (server) => chosen = server);

    await _submit(tester, 'slim-beta.example.top');
    await waitUntil(tester, () => chosen != null);

    expect(chosen, Uri.parse('https://slim-beta.example.top'));
  });

  testWidgets('a host and port connects over https on that port', (
    tester,
  ) async {
    Uri? chosen;
    await _pump(tester, onChosen: (server) => chosen = server);

    await _submit(tester, 'chat.example:8443');
    await waitUntil(tester, () => chosen != null);

    expect(chosen, Uri.parse('https://chat.example:8443'));
  });

  testWidgets('Continue is busy while the address answers', (tester) async {
    Uri? chosen;
    final gate = Completer<void>();
    await _pump(
      tester,
      onChosen: (server) => chosen = server,
      answerGate: gate.future,
    );

    await _submit(tester, 'chat.example');
    await pumpFrames(tester);

    final continueButton = tester.widget<AppButton>(
      find.ancestor(
        of: find.text('Continue'),
        matching: find.byWidgetPredicate((w) => w is AppButton),
      ),
    );
    expect(continueButton.busy, isTrue);
    expect(chosen, isNull);

    gate.complete();
    await waitUntil(tester, () => chosen != null);
    expect(chosen, Uri.parse('https://chat.example'));
  });

  testWidgets('the first press shows the error and the dialog keeps its size', (
    tester,
  ) async {
    await _pump(tester, onChosen: (_) {});
    final before = tester.getRect(find.text('Cancel'));

    await _submit(tester, 'not an address');
    await tester.pump();

    expect(
      find.text('That does not look like a server address.'),
      findsOneWidget,
    );
    expect(tester.getRect(find.text('Cancel')), before);
  });

  testWidgets('a scheme typed without :// is refused, not read as a host', (
    tester,
  ) async {
    Uri? chosen;
    await _pump(tester, onChosen: (address) => chosen = address);

    await _submit(tester, 'http:/chat.example');
    await tester.pump();

    expect(
      find.text(
        'Check the start of the address. It should begin with https://',
      ),
      findsOneWidget,
    );
    expect(chosen, isNull);
  });
}
