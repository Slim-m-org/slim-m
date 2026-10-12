// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Walks the way a new person joins the official Space, screen by screen, and
/// pins that the self-hosted path keeps every step the official one drops.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_app/src/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mock_app_version.dart';
import 'ui_snapshot_support.dart';

const _sizes = {'phone': Size(390, 844), 'desktop': Size(1400, 880)};

const _identity = {
  'public_key': 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=',
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

http.Client _server() => MockClient((request) async {
  const headers = {'content-type': 'application/json'};
  if (request.url.path == '/version') {
    return http.Response(
      jsonEncode({
        'name': 'slim-m',
        'version': '0.6.0',
        'protocol': 1,
        'identity': _identity,
      }),
      200,
      headers: headers,
    );
  }
  if (request.url.path.startsWith('/invites/')) {
    return http.Response(
      jsonEncode({
        'usable': true,
        'community': {'name': 'slim-m', 'member_count': 3},
      }),
      200,
      headers: headers,
    );
  }
  return http.Response('{}', 404);
});

/// Onboarding, then sign-in on whichever server it hands over.
Future<void> _pump(
  WidgetTester tester, {
  required Size size,
  ({Uri server, String code})? tapped,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  Uri chosen = Uri.parse('http://unset.invalid');
  final client = _server();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => chosen),
      if (tapped != null) tappedInviteProvider.overrideWith((ref) => tapped),
      probeApiProvider.overrideWithValue(
        (baseUrl) => SlimmApi(baseUrl: baseUrl, httpClient: client),
      ),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          navigatorKey: navigator,
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: OnboardingScreen(
            onServerChosen: (server, code) {
              chosen = server;
              container.read(pendingInviteProvider.notifier).state = code;
              container.invalidate(serverUrlProvider);
              navigator.currentState!.push(
                MaterialPageRoute<void>(builder: (_) => const SignInScreen()),
              );
            },
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _acceptAndContinue(WidgetTester tester) async {
  await tester.tap(find.byType(CheckboxListTile));
  await tester.pump();
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Join'));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(mockAppVersion);

  for (final MapEntry(key: name, value: size) in _sizes.entries) {
    testWidgets('$name: official button goes straight to username and '
        'password', (tester) async {
      await _pump(tester, size: size);
      await writeSnapshot(tester, 'join-1-onboarding-$name');
      await tester.tap(find.text('Join the official Space'));
      await tester.pumpAndSettle();
      await writeSnapshot(tester, 'join-2-official-signup-$name');

      expect(find.text('SECURITY CHECK'), findsNothing);
      expect(find.text('Create an account'), findsWidgets);
      expect(find.text('Server'), findsNothing);
      expect(find.text('Display name'), findsNothing);
      expect(find.byType(TextField), findsNWidgets(2));
    });

    testWidgets('$name: tapped invite link to the official server asks '
        'for no address and shows no fingerprint screen', (tester) async {
      await _pump(
        tester,
        size: size,
        tapped: (server: Uri.parse(officialServer), code: 'C1'),
      );

      expect(find.text('Joining slim.npc-server.top'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget, reason: 'the code only');
      await writeSnapshot(tester, 'join-3-official-invite-dialog-$name');

      await _acceptAndContinue(tester);

      expect(find.text('SECURITY CHECK'), findsNothing);
      expect(find.text('Create an account'), findsWidgets);
      expect(find.text('Display name'), findsNothing);
      await writeSnapshot(tester, 'join-4-official-invite-signup-$name');
    });
  }

  testWidgets('self-hosted invite link keeps the security check, and the '
      'server can still be changed', (tester) async {
    await _pump(
      tester,
      size: _sizes['desktop']!,
      tapped: (server: Uri.parse('https://chat.example'), code: 'C1'),
    );

    expect(find.text('Joining chat.example'), findsOneWidget);
    await writeSnapshot(tester, 'join-5-selfhost-invite-dialog-desktop');
    await tester.tap(find.text('Use a different server'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNWidgets(2));

    await _acceptAndContinue(tester);

    expect(find.text('SECURITY CHECK'), findsOneWidget);
  });
}
