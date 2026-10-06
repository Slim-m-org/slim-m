// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_dialogs.dart';
import 'package:slimm_app/src/screens/reset_password_sheet.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

final _server = Uri.parse('https://chat.example');

Future<void> _open(
  WidgetTester tester,
  http.Client client,
  Future<void> Function(BuildContext) opener,
) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => _server),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  tester.view.physicalSize = const Size(1000, 1600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () => opener(context),
                child: const Text('open'),
              ),
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
  testWidgets('reset sheet dismissed while the request fails throws no error', (
    tester,
  ) async {
    final gate = Completer<void>();
    final client = MockClient((request) async {
      await gate.future;
      return http.Response(
        jsonEncode({'error': 'that reset code cannot be used'}),
        400,
        headers: const {'content-type': 'application/json'},
      );
    });
    await _open(tester, client, (c) => showResetPasswordSheet(c, _server));
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'some-code');
    await tester.enterText(fields.at(1), 'a-long-enough-pass');
    await tester.pump();
    await tester.tap(find.text('Set new password'));
    await tester.pump();
    // dismiss by barrier tap while the request is in flight
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.text('Use a reset code'),
      findsNothing,
      reason: 'sheet dismissed',
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('invite dialog dismissed while the probe fails throws no error', (
    tester,
  ) async {
    final gate = Completer<void>();
    final client = MockClient((request) async {
      await gate.future;
      return http.Response(
        jsonEncode({'error': 'nope'}),
        500,
        headers: const {'content-type': 'application/json'},
      );
    });
    await _open(
      tester,
      client,
      (c) =>
          showAppSheet<(Uri, String)>(c, builder: (c) => const InviteDialog()),
    );
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'https://chat.example');
    await tester.enterText(fields.at(1), 'CODE');
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pump();
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(
      find.text('Redeem an invite'),
      findsNothing,
      reason: 'sheet dismissed',
    );
    gate.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
