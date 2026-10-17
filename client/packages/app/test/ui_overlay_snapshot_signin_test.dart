// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign-in's server-probe notices and its `_submit` failure states: neither
/// is a `show*` one-shot, both need a typed address and a mocked network
/// answer, so this drives `SignInScreen` directly with `tester`, the same
/// shape `sign_in_screen_identity_test.dart` already proved out.
///
/// Split from `ui_overlay_snapshot_onboarding_test.dart` to keep both under
/// this repo's line budget; see that file's own doc for the shared reasoning
/// on why these are not `_overlays`-map entries. One viewport (desktop).
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

import 'support/mid_flight_capture.dart';
import 'support/mock_app_version.dart';
import 'support/onboarding_error_strings.dart';
import 'ui_snapshot_support.dart';

final _errorStrings = OnboardingErrorStrings.load();

const _viewport = Size(1400, 880);
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

String _handleFor(String server) => 'server_identity:$server';

/// [versionBody] answers every `/version` probe. [authResponder] answers
/// `/auth/login` and `/auth/register`; a null one leaves both at the fake
/// client's plain `{}` 200, which is enough for the probe-only states below.
Future<ProviderContainer> _pumpSignIn(
  WidgetTester tester, {
  Map<String, Object?>? versionBody,
  http.Response Function(http.Request)? authResponder,
  KeyStore? keyStore,
  bool pendingInvite = false,
}) async {
  final httpClient = MockClient((request) async {
    if (request.method == 'GET' && request.url.path == '/version') {
      return http.Response(
        jsonEncode(versionBody ?? const {}),
        200,
        headers: const {'content-type': 'application/json'},
      );
    }
    if (authResponder != null &&
        (request.url.path == '/auth/login' ||
            request.url.path == '/auth/register')) {
      return authResponder(request);
    }
    return http.Response('{}', 200);
  });

  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(keyStore ?? InMemoryKeyStore()),
      serverUrlProvider.overrideWith((ref) => Uri.parse(_server)),
      if (pendingInvite)
        pendingInviteProvider.overrideWith((ref) => 'DEADCODE1'),
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

  tester.view.physicalSize = _viewport;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: RepaintBoundary(
        key: snapshotBoundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: const SignInScreen(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

Future<void> _finish(WidgetTester tester, String name) async {
  await expectSettled(tester, name);
  await writeSnapshot(tester, name);
  expect(tester.takeException(), isNull);
}

http.Response _jsonResponse(Map<String, Object?> body, int status) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: const {'content-type': 'application/json'},
    );

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  group('probe notices', () {
    testWidgets('creating an account shows the extra display-name field '
        'and the identity stepper', (tester) async {
      await _pumpSignIn(tester, pendingInvite: true);
      expect(find.text('Create an account'), findsOneWidget);
      expect(find.text('Display name'), findsOneWidget);
      await _finish(tester, 'sign-in-mode-create-account-desktop');
    });

    testWidgets('an unpinned identity shows the unknown chip', (tester) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'identity': _identityA,
          'capabilities': ['report', 'block'],
        },
      );
      await _finish(tester, 'identity-chip-unknown-desktop');
    });

    testWidgets('a pin matching the fetched key shows the confirmed tick', (
      tester,
    ) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(
        _handleFor(_server),
        _identityA['public_key'] as String,
      );
      await _pumpSignIn(
        tester,
        keyStore: keyStore,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'identity': _identityA,
          'capabilities': ['report', 'block'],
        },
      );
      await _finish(tester, 'identity-chip-confirmed-desktop');
    });

    testWidgets('a pin that no longer matches shows the mismatch glyph', (
      tester,
    ) async {
      final keyStore = InMemoryKeyStore();
      await keyStore.put(_handleFor(_server), 'a-completely-different-key');
      await _pumpSignIn(
        tester,
        keyStore: keyStore,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'identity': _identityA,
          'capabilities': ['report', 'block'],
        },
      );
      await _finish(tester, 'identity-chip-mismatch-desktop');
    });

    testWidgets('a server too old to say has no verdict, only a caveat', (
      tester,
    ) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.10.0',
          'protocol': 1,
        },
      );
      expect(find.textContaining('too old to say'), findsOneWidget);
      await _finish(tester, 'safety-notice-unknown-desktop');
    });

    testWidgets('neither report nor block offered', (tester) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'capabilities': <String>[],
        },
      );
      expect(find.textContaining('no way to report'), findsOneWidget);
      await _finish(tester, 'safety-notice-missing-both-desktop');
    });

    testWidgets('report absent, block present', (tester) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'capabilities': ['block'],
        },
      );
      await _finish(tester, 'safety-notice-missing-report-desktop');
    });

    testWidgets('block absent, report present', (tester) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'capabilities': ['report'],
        },
      );
      await _finish(tester, 'safety-notice-missing-block-desktop');
    });

    testWidgets('invite required, shown only while creating an account', (
      tester,
    ) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'invite_required': true,
          'capabilities': ['report', 'block'],
        },
      );
      await tester.tap(find.text('Create an account instead'));
      await tester.pumpAndSettle();
      expect(find.textContaining('invite code'), findsOneWidget);
      await _finish(tester, 'invite-required-notice-desktop');
    });

    testWidgets('a server that cannot push says so', (tester) async {
      await _pumpSignIn(
        tester,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.17.0',
          'protocol': 1,
          'push_enabled': false,
          'capabilities': ['report', 'block'],
        },
      );
      expect(find.textContaining('cannot send push'), findsOneWidget);
      await _finish(tester, 'push-disabled-notice-desktop');
    });

    // An old, invite-only, push-disabled, safety-incomplete server stacks the chip and all three notices at once.
    testWidgets('every notice at once, on a server that fails every check', (
      tester,
    ) async {
      await _pumpSignIn(
        tester,
        pendingInvite: true,
        versionBody: const {
          'name': 'slim-m',
          'version': '0.14.2',
          'protocol': 1,
          'invite_required': true,
          'push_enabled': false,
          'capabilities': <String>[],
        },
      );
      await _finish(tester, 'probe-notices-stacked-desktop');
    });
  });

  group('submit failures', () {
    Future<void> submitSignIn(WidgetTester tester) async {
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();
    }

    testWidgets('wrong username or password', (tester) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) => _jsonResponse({'error': 'bad credentials'}, 401),
      );
      await submitSignIn(tester);
      expect(find.text('Wrong username or password.'), findsOneWidget);
      await _finish(tester, 'submit-wrong-credentials-desktop');
    });

    testWidgets('username already taken, register mode', (tester) async {
      await _pumpSignIn(
        tester,
        pendingInvite: true,
        authResponder: (r) => _jsonResponse({'error': 'taken'}, 409),
      );
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(3), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Create account'));
      await tester.pumpAndSettle();
      expect(find.text('That username is already taken.'), findsOneWidget);
      await _finish(tester, 'submit-username-taken-desktop');
    });

    /// The real string http/auth.rs's validate_password sends for this
    /// failure, not an invented approximation.
    testWidgets('a bad request names what the server rejected', (tester) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) =>
            _jsonResponse({'error': _errorStrings.passwordLengthError}, 400),
      );
      await submitSignIn(tester);
      expect(
        find.text(sentenceCase(_errorStrings.passwordLengthError)),
        findsOneWidget,
      );
      await _finish(tester, 'submit-bad-request-desktop');
    });

    testWidgets('rate limited', (tester) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) => _jsonResponse({'error': 'slow down'}, 429),
      );
      await submitSignIn(tester);
      expect(find.textContaining('Too many attempts'), findsOneWidget);
      await _finish(tester, 'submit-rate-limited-desktop');
    });

    testWidgets('the server is busy', (tester) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) => _jsonResponse({'error': 'unavailable'}, 503),
      );
      await submitSignIn(tester);
      expect(find.textContaining('server is busy'), findsOneWidget);
      await _finish(tester, 'submit-server-unavailable-desktop');
    });

    testWidgets('unreachable: nothing was sent', (tester) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) => throw Exception('connection refused'),
      );
      await submitSignIn(tester);
      expect(find.textContaining("didn't answer"), findsOneWidget);
      await _finish(tester, 'submit-unreachable-desktop');
    });

    testWidgets('a generic refusal carries the server\'s own message', (
      tester,
    ) async {
      await _pumpSignIn(
        tester,
        authResponder: (r) => _jsonResponse({'error': 'teapot'}, 418),
      );
      await submitSignIn(tester);
      expect(find.textContaining('The server refused that.'), findsOneWidget);
      await _finish(tester, 'submit-generic-refusal-desktop');
    });

    testWidgets('an address that does not parse never reaches the network', (
      tester,
    ) async {
      var calls = 0;
      await _pumpSignIn(
        tester,
        authResponder: (r) {
          calls++;
          return _jsonResponse(const {}, 200);
        },
      );
      await tester.enterText(find.byType(TextField).first, 'not a url');
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(
        find.text('That does not look like a server address.'),
        findsOneWidget,
      );
      expect(calls, 0);
      await _finish(tester, 'submit-address-error-desktop');
    });

    testWidgets('a public http address is refused before it is sent', (
      tester,
    ) async {
      await _pumpSignIn(tester);
      await tester.enterText(
        find.byType(TextField).first,
        'http://chat.example.com',
      );
      await tester.enterText(find.byType(TextField).at(1), 'alice');
      await tester.enterText(find.byType(TextField).at(2), 'hunter2');
      await tester.tap(find.widgetWithText(AppButton, 'Sign in'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Use https'), findsOneWidget);
      await _finish(tester, 'submit-scheme-refused-desktop');
    });
  });
}
