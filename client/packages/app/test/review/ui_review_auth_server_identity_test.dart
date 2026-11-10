// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing a server by address, and the two trust-on-first-use identity
/// steps that follow it: the first-connect fingerprint and the changed-key
/// warning, the latter also as the gate over a signed-in session. Phone and
/// desktop, dark and light, one mount each.
///
/// The steps are reached through onboarding's manual dialog against a server
/// presenting a chosen identity, as a person reaches them.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/screens/onboarding_screen.dart';
import 'package:slimm_app/src/features/auth/screens/sign_in_screen.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../support/mock_app_version.dart';
import '../ui_snapshot_support.dart' show fixtureResponse;
import 'review_auth_support.dart';
import 'review_support.dart';

Future<void> _manual(
  WidgetTester tester,
  String viewport,
  String state, {
  ScriptedServer? server,
  ReviewAct? act,
}) => reviewWidget(
  tester,
  surface: 'dialog-onboarding-manual-server',
  state: state,
  viewport: viewport,
  build: onboardingScreen,
  overrides: authOverrides(server ?? ScriptedServer()),
  act: act,
);

Map<String, Object?> _presenting(Map<String, Object?> identity) => {
  ...modernVersion,
  'identity': identity,
};

/// Onboarding's manual dialog, submitted, which is what pushes an identity step.
ReviewAct _toIdentityStep(String heading, [ReviewAct? then]) =>
    (tester, handles) async {
      await tapLabel(tester, 'Connect to a Space');
      await typeInto(tester, 'Server address', authServer);
      await tapLabel(tester, 'Continue');
      expect(find.text(heading), findsOneWidget);
      if (then != null) await then(tester, handles);
    };

Future<void> _fingerprint(
  WidgetTester tester,
  String viewport,
  String state, [
  ReviewAct? then,
]) => reviewWidget(
  tester,
  surface: 'auth-server-fingerprint-step',
  state: state,
  viewport: viewport,
  build: onboardingScreen,
  overrides: authOverrides(ScriptedServer(version: _presenting(identityA))),
  act: _toIdentityStep('Confirm this server', then),
);

Future<void> _changed(
  WidgetTester tester,
  String viewport,
  String state, [
  ReviewAct? then,
]) async => reviewWidget(
  tester,
  surface: 'auth-server-identity-changed',
  state: state,
  viewport: viewport,
  build: onboardingScreen,
  overrides: authOverrides(
    ScriptedServer(version: _presenting(identityB)),
    keyStore: await pinnedKeyStore(identityA['public_key']! as String),
  ),
  act: _toIdentityStep("This server's identity changed", then),
);

const _acknowledge =
    'I have confirmed this new code with whoever runs this server.';

/// A signed-in session on the channel shell whose server now presents another key.
Future<void> _gate(WidgetTester tester, String viewport) async {
  final store = await pinnedKeyStore(identityA['public_key']! as String);
  final client = MockClient(
    (request) async => request.url.path == '/version'
        ? jsonResponse(_presenting(identityB))
        : fixtureResponse(request),
  );
  return reviewRoute(
    tester,
    surface: 'auth-server-identity-changed',
    state: 'signed-in-gate',
    viewport: viewport,
    overrides: [
      keyStoreProvider.overrideWithValue(store),
      serverUrlProvider.overrideWith((ref) => Uri.parse(authServer)),
      apiProvider.overrideWith(
        (ref) => api.SlimmApi(
          baseUrl: Uri.parse(authServer),
          session: ref.watch(sessionProvider),
          httpClient: client,
        ),
      ),
    ],
    act: (tester, _) async {
      await settleReview(tester);
      await settleReview(tester);
      expect(find.text("This server's identity changed"), findsOneWidget);
    },
  );
}

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  reviewCases(
    'dialog-onboarding-manual-server',
    state: 'empty',
    body: (tester, viewport) => _manual(
      tester,
      viewport,
      'empty',
      act: (tester, _) => tapLabel(tester, 'Connect to a Space'),
    ),
  );

  reviewCases(
    'dialog-onboarding-manual-server',
    state: 'address-error',
    body: (tester, viewport) => _manual(
      tester,
      viewport,
      'address-error',
      act: submitManualAddress('not a url'),
    ),
  );

  reviewCases(
    'dialog-onboarding-manual-server',
    state: 'scheme-refused',
    body: (tester, viewport) => _manual(
      tester,
      viewport,
      'scheme-refused',
      act: submitManualAddress('http://chat.example.com'),
    ),
  );

  // The dialog has already closed while the identity probe is out, so this is the bare screen with nothing saying it is waiting.
  reviewCases(
    'dialog-onboarding-manual-server',
    state: 'checking',
    body: (tester, viewport) {
      final hold = Completer<void>();
      return whileHolding(
        tester,
        hold,
        () => _manual(
          tester,
          viewport,
          'checking',
          server: ScriptedServer(versionHold: hold),
          act: submitManualAddress(authServer),
        ),
      );
    },
  );

  // An unreachable probe counts as unknown, so the flow carries on to sign-in, which is what the person sees.
  reviewCases(
    'dialog-onboarding-manual-server',
    state: 'unreachable',
    body: (tester, viewport) => reviewRoute(
      tester,
      surface: 'dialog-onboarding-manual-server',
      state: 'unreachable',
      viewport: viewport,
      route: '/',
      router: _joinRouter(),
      overrides: authOverrides(ScriptedServer(versionFails: true)),
      act: submitManualAddress(authServer),
    ),
  );

  reviewCases(
    'auth-server-fingerprint-step',
    state: 'default',
    body: (tester, viewport) => _fingerprint(tester, viewport, 'default'),
  );

  // The step has no busy state, so this is its one other: the copy button after a tap.
  reviewCases(
    'auth-server-fingerprint-step',
    state: 'copied',
    body: (tester, viewport) => _fingerprint(
      tester,
      viewport,
      'copied',
      (tester, _) => tapLabel(tester, 'Copy this code'),
    ),
  );

  reviewCases(
    'auth-server-identity-changed',
    state: 'unacknowledged',
    body: (tester, viewport) => _changed(tester, viewport, 'unacknowledged'),
  );

  reviewCases(
    'auth-server-identity-changed',
    state: 'acknowledged',
    body: (tester, viewport) => _changed(
      tester,
      viewport,
      'acknowledged',
      (tester, _) => tapLabel(tester, _acknowledge),
    ),
  );

  reviewCases(
    'auth-server-identity-changed',
    state: 'signed-in-gate',
    body: _gate,
  );
}

GoRouter _joinRouter() => GoRouter(
  routes: [
    GoRoute(
      path: '/',
      builder: (context, _) => OnboardingScreen(
        onServerChosen: (server, invite) => context.go('/sign-in'),
      ),
    ),
    GoRoute(path: '/sign-in', builder: (context, _) => const SignInScreen()),
  ],
);
