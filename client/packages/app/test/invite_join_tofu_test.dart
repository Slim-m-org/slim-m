// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Trust on first use along the invite path: the security check shows the
/// first time a device joins a server and never again while the pinned key
/// matches. See decision 0036.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _server = 'https://chat.example';
const _handle = 'server_identity:$_server';
const _keyA = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
const _keyB = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=';

Map<String, Object?> _identity(String key) => {
  'public_key': key,
  'fingerprint': 'deadbeefcafebabefeedface1337d00d',
  'fingerprint_groups': [
    'dead',
    'beef',
    'cafe',
    'babe',
    'feed',
    'face',
    '1337',
    'd00d',
  ],
  'color_strip': [0, 1, 2, 3],
};

/// Pumps onboarding and submits the invite dialog for [_server], leaving
/// whatever the identity check does next for the test to assert on.
Future<void> _startInvite(
  WidgetTester tester, {
  required KeyStore keyStore,
  required String servedKey,
  required void Function(Uri, String?) onChosen,
}) async {
  final httpClient = MockClient((request) async {
    final Object body = request.url.path == '/version'
        ? {
            'name': 'slim-m',
            'version': '0.10.0',
            'protocol': 1,
            'identity': _identity(servedKey),
          }
        : {
            'usable': true,
            'community': {
              'name': 'Space',
              'member_count': 3,
              'invited_by': 'alice',
              'uses_remaining': null,
              'expires_at': null,
            },
          };
    return http.Response(
      jsonEncode(body),
      200,
      headers: const {'content-type': 'application/json'},
    );
  });
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore),
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
        home: OnboardingScreen(onServerChosen: onChosen),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('I have an invite'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField).first, _server);
  await tester.enterText(find.byType(TextField).at(1), 'CODE123');
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Join'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a repeat invite join to a pinned server skips the check', (
    tester,
  ) async {
    Uri? chosen;
    String? code;
    final keyStore = InMemoryKeyStore();
    await keyStore.put(_handle, _keyA);

    await _startInvite(
      tester,
      keyStore: keyStore,
      servedKey: _keyA,
      onChosen: (s, c) {
        chosen = s;
        code = c;
      },
    );

    expect(find.text('Confirm this server'), findsNothing);
    expect(find.text("This server's identity changed"), findsNothing);
    expect(chosen, Uri.parse(_server));
    expect(code, 'CODE123');
  });

  testWidgets('storage that was cleared falls back to the first-join check', (
    tester,
  ) async {
    Uri? chosen;
    await _startInvite(
      tester,
      keyStore: InMemoryKeyStore(),
      servedKey: _keyA,
      onChosen: (s, c) => chosen = s,
    );

    expect(find.text('Confirm this server'), findsOneWidget);
    expect(chosen, isNull);
  });

  testWidgets('an invite join to a changed key shows the mismatch warning and '
      'needs an explicit acknowledgement', (tester) async {
    Uri? chosen;
    final keyStore = InMemoryKeyStore();
    await keyStore.put(_handle, _keyA);

    await _startInvite(
      tester,
      keyStore: keyStore,
      servedKey: _keyB,
      onChosen: (s, c) => chosen = s,
    );

    expect(find.text("This server's identity changed"), findsOneWidget);
    expect(find.text('Confirm this server'), findsNothing);
    expect(chosen, isNull);
    expect(await keyStore.read(_handle), _keyA);

    await tester.ensureVisible(find.byType(Checkbox));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.text('Trust the new identity'));
    await tester.pumpAndSettle();

    expect(chosen, Uri.parse(_server));
    expect(await keyStore.read(_handle), _keyB);
  });
}
