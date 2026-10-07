// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for the server-identity confirmation step in the manual "connect to
/// a server" flow: pin on first connect, stay silent on a later match, and
/// force an explicit, non-default action through if the key ever changes.
///
/// Userinfo stripping lives in onboarding_screen_userinfo_test.dart, and
/// phone-width modal presentation in onboarding_screen_phone_test.dart.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/default_server.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/onboarding_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _server = 'https://chat.example';

const _identityA = {
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

const _identityB = {
  'public_key': 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=',
  'fingerprint': 'facefeedf00dd00dfacefeedf00dd00d',
  'fingerprint_groups': [
    'face',
    'feed',
    'f00d',
    'd00d',
    'face',
    'feed',
    'f00d',
    'd00d',
  ],
  'color_strip': [4, 5, 0, 1],
};

String _handleFor(String server) => 'server_identity:$server';

Future<ProviderContainer> _pumpOnboarding(
  WidgetTester tester, {
  required Map<String, Object?> versionBody,
  KeyStore? keyStore,
  required void Function(Uri, String?) onServerChosen,
}) async {
  final httpClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode(versionBody),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore ?? InMemoryKeyStore()),
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
        home: OnboardingScreen(onServerChosen: onServerChosen),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

/// Opens the manual-connect dialog and submits [_server], leaving whatever
/// the identity check does next (silent, a confirmation step, or a warning)
/// for the test to assert on.
Future<void> _enterManualServer(WidgetTester tester) async {
  await tester.tap(find.text('Connect to a Space'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), _server);
  await tester.tap(find.text('Continue'));
  await tester.pumpAndSettle();
}

/// Scrolls a labelled control into view before tapping it: the identity
/// screens are tall enough, once a long warning and a checkbox are both on
/// screen, that a button can sit below a short test viewport without this.
Future<void> _tapButton(WidgetTester tester, String label) async {
  final finder = find.text(label);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a server too old to report an identity is not blocked on one', (
    tester,
  ) async {
    Uri? chosen;
    final container = await _pumpOnboarding(
      tester,
      versionBody: const {'name': 'slim-m', 'version': '0.6.0', 'protocol': 1},
      onServerChosen: (server, invite) => chosen = server,
    );

    await _enterManualServer(tester);

    expect(chosen, Uri.parse(_server));
    expect(find.text('Confirm this server'), findsNothing);
    expect(
      container.read(assumeNewAccountProvider),
      isFalse,
      reason:
          'a manually-typed address is not the compiled-in official server, '
          'so sign-in must still default to signing in, not creating',
    );
  });

  testWidgets('the first connection to a server shows its fingerprint, and '
      'confirming it pins the key and proceeds', (tester) async {
    Uri? chosen;
    final keyStore = InMemoryKeyStore();
    await _pumpOnboarding(
      tester,
      versionBody: const {
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'identity': _identityA,
      },
      keyStore: keyStore,
      onServerChosen: (server, invite) => chosen = server,
    );

    await _enterManualServer(tester);

    expect(find.text('Confirm this server'), findsOneWidget);
    expect(find.text(_server), findsOneWidget);
    // Derived from the pinned key (sha256 of 32 zero bytes), not the wire field.
    expect(find.text('6668  7aad  f862  bd77'), findsOneWidget);
    expect(chosen, isNull, reason: 'must wait for explicit confirmation');

    await _tapButton(tester, 'It matches - continue');

    expect(chosen, Uri.parse(_server));
    expect(await keyStore.read(_handleFor(_server)), _identityA['public_key']);
  });

  testWidgets('cancelling the first-connect fingerprint step pins nothing', (
    tester,
  ) async {
    Uri? chosen;
    final keyStore = InMemoryKeyStore();
    await _pumpOnboarding(
      tester,
      versionBody: const {
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'identity': _identityA,
      },
      keyStore: keyStore,
      onServerChosen: (server, invite) => chosen = server,
    );

    await _enterManualServer(tester);
    await _tapButton(tester, 'Cancel');

    expect(chosen, isNull);
    expect(await keyStore.read(_handleFor(_server)), isNull);
  });

  testWidgets('a later connection matching the pinned key never shows the step '
      'again', (tester) async {
    Uri? chosen;
    final keyStore = InMemoryKeyStore();
    await keyStore.put(_handleFor(_server), _identityA['public_key'] as String);

    await _pumpOnboarding(
      tester,
      versionBody: const {
        'name': 'slim-m',
        'version': '0.10.0',
        'protocol': 1,
        'identity': _identityA,
      },
      keyStore: keyStore,
      onServerChosen: (server, invite) => chosen = server,
    );

    await _enterManualServer(tester);

    expect(find.text('Confirm this server'), findsNothing);
    expect(chosen, Uri.parse(_server));
  });

  group('a pinned key that no longer matches', () {
    testWidgets(
      'is shown as a distinct warning that blocks the risky action until '
      'it is explicitly acknowledged',
      (tester) async {
        Uri? chosen;
        final keyStore = InMemoryKeyStore();
        await keyStore.put(
          _handleFor(_server),
          _identityA['public_key'] as String,
        );

        await _pumpOnboarding(
          tester,
          versionBody: const {
            'name': 'slim-m',
            'version': '0.10.0',
            'protocol': 1,
            'identity': _identityB,
          },
          keyStore: keyStore,
          onServerChosen: (server, invite) => chosen = server,
        );

        await _enterManualServer(tester);

        expect(find.text("This server's identity changed"), findsOneWidget);
        expect(find.text('Confirm this server'), findsNothing);

        // Tapping the risky action before acknowledging must do nothing: this
        // is the one screen a plain tap-through is not allowed to work.
        await _tapButton(tester, 'Trust the new identity');
        expect(chosen, isNull);
        expect(find.text("This server's identity changed"), findsOneWidget);

        await tester.ensureVisible(find.byType(Checkbox));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Checkbox));
        await tester.pump();
        await _tapButton(tester, 'Trust the new identity');

        expect(chosen, Uri.parse(_server));
        expect(
          await keyStore.read(_handleFor(_server)),
          _identityB['public_key'],
        );
      },
    );

    testWidgets('cancelling leaves the old pinned key untouched', (
      tester,
    ) async {
      Uri? chosen;
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        _handleFor(_server),
        _identityA['public_key'] as String,
      );

      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
          'identity': _identityB,
        },
        keyStore: keyStore,
        onServerChosen: (server, invite) => chosen = server,
      );

      await _enterManualServer(tester);
      await _tapButton(tester, 'Cancel');

      expect(chosen, isNull);
      expect(
        await keyStore.read(_handleFor(_server)),
        _identityA['public_key'],
      );
    });
  });

  group('the https rule', () {
    testWidgets('the manual dialog still refuses a public http address', (
      tester,
    ) async {
      await _pumpOnboarding(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.6.0',
          'protocol': 1,
        },
        onServerChosen: (server, invite) {},
      );

      await tester.tap(find.text('Connect to a Space'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'http://chat.example.com');
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Use https'), findsOneWidget);
    });
  });

  group('pinning identity on paths that previously pinned nothing', () {
    testWidgets('choosing the official Space pins its identity', (
      tester,
    ) async {
      final keyStore = InMemoryKeyStore();
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'slim-m',
              'version': '0.10.0',
              'protocol': 1,
              'identity': _identityA,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      Uri? chosen;
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
            home: OnboardingScreen(
              onServerChosen: (server, invite) => chosen = server,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Join the official Space'));
      await tester.pumpAndSettle();

      expect(
        find.text('Confirm this server'),
        findsNothing,
        reason:
            'the official server has no admin to read a fingerprint to, so '
            'first connect pins silently instead of asking',
      );
      expect(chosen, Uri.parse(officialServer));
      expect(
        await keyStore.read('server_identity:$officialServer'),
        _identityA['public_key'],
      );
      expect(
        container.read(assumeNewAccountProvider),
        isTrue,
        reason:
            'this button only ever appears with no server chosen before, so '
            'sign-in should open on creating an account, not signing in',
      );
    });

    testWidgets('redeeming an invite for the first time pins its identity', (
      tester,
    ) async {
      final keyStore = InMemoryKeyStore();
      final httpClient = MockClient((request) async {
        if (request.method == 'GET' && request.url.path == '/version') {
          return http.Response(
            jsonEncode({
              'name': 'slim-m',
              'version': '0.10.0',
              'protocol': 1,
              'identity': _identityA,
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        if (request.method == 'GET' && request.url.path.endsWith('/check')) {
          return http.Response(
            jsonEncode({
              'usable': true,
              'community': {
                'name': 'Space',
                'member_count': 3,
                'invited_by': 'alice',
                'uses_remaining': null,
                'expires_at': null,
              },
            }),
            200,
            headers: const {'content-type': 'application/json'},
          );
        }
        return http.Response('{}', 200);
      });

      Uri? chosen;
      String? redeemedCode;
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
            home: OnboardingScreen(
              onServerChosen: (server, invite) {
                chosen = server;
                redeemedCode = invite;
              },
            ),
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

      expect(
        find.text('Confirm this server'),
        findsOneWidget,
        reason: 'nothing was pinned for an invited address before this',
      );
      await _tapButton(tester, 'It matches - continue');

      expect(chosen, Uri.parse(_server));
      expect(redeemedCode, 'CODE123');
      expect(
        await keyStore.read(_handleFor(_server)),
        _identityA['public_key'],
      );
    });
  });
}
