// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Sign-in and create-account in every state a person can be left in: each
/// refusal the server can give, each answer the address probe can come back
/// with, and the reasons the screen can be in front of someone at all.
///
/// The server is scripted (`review_auth_support.dart`) and the screen is
/// driven by typing and tapping, so what is captured is what a person sees.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/api_failure.dart';
import 'package:slimm_app/src/features/share/providers/incoming_share.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../support/mock_app_version.dart';
import '../support/onboarding_error_strings.dart';
import 'review_auth_support.dart';
import 'review_support.dart';

final _errorStrings = OnboardingErrorStrings.load();

const _claimedVersion = {
  ...modernVersion,
  'claimed': true,
  'invite_required': true,
};

Future<void> _signIn(
  WidgetTester tester,
  String viewport,
  String surface,
  String state, {
  Map<String, Object?> version = modernVersion,
  http.Response Function(http.Request)? auth,
  String? pinned,
  List<Override> extra = const [],
  ReviewAct? act,
}) async => reviewRoute(
  tester,
  surface: surface,
  state: state,
  viewport: viewport,
  route: '/sign-in',
  overrides: [
    // Signed out, as this screen only ever is: a signed-in session would trip the identity gate.
    sessionProvider.overrideWithValue(api.SessionStore()),
    ...authOverrides(
      ScriptedServer(version: version, auth: auth),
      keyStore: pinned == null ? null : await pinnedKeyStore(pinned),
      signInApi: true,
    ),
    ...extra,
  ],
  act: act,
);

Finder _button(String label) => find.widgetWithText(AppButton, label);

/// Types a username and password, presses [button], and expects [message].
ReviewAct _submit(
  String message, {
  String button = 'Sign in',
  String password = 'hunter2',
}) => (tester, handles) async {
  await typeInto(tester, 'Username', 'alice');
  await typeInto(tester, 'Password', password);
  await tester.tap(_button(button));
  await settleReview(tester);
  expect(find.textContaining(message), findsOneWidget);
};

http.Response Function(http.Request) _refuse(Object body, int status) =>
    (request) => jsonResponse(body, status);

void _refusal(
  String state,
  String message,
  http.Response Function(http.Request) auth,
) => reviewCases(
  'auth-sign-in',
  state: state,
  body: (tester, viewport) => _signIn(
    tester,
    viewport,
    'auth-sign-in',
    state,
    auth: auth,
    act: _submit(message),
  ),
);

void _probe(
  String state,
  Map<String, Object?> version, {
  String? pinnedKey,
  List<Override> extra = const [],
}) => reviewCases(
  'auth-sign-in',
  state: state,
  body: (tester, viewport) => _signIn(
    tester,
    viewport,
    'auth-sign-in',
    state,
    version: version,
    pinned: pinnedKey,
    extra: extra,
  ),
);

void _registerCase(
  String state, {
  Map<String, Object?> version = modernVersion,
  http.Response Function(http.Request)? auth,
  ReviewAct? act,
  bool invite = true,
}) => reviewCases(
  'auth-sign-in-register',
  state: state,
  body: (tester, viewport) => _signIn(
    tester,
    viewport,
    'auth-sign-in-register',
    state,
    version: version,
    auth: auth,
    act: act,
    extra: [
      if (invite) pendingInviteProvider.overrideWith((ref) => 'DEADCODE1'),
    ],
  ),
);

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  _refusal(
    'wrong-credentials',
    'Wrong username or password.',
    _refuse({'error': 'bad credentials'}, 401),
  );
  _refusal(
    'rate-limited',
    'Too many attempts',
    _refuse({'error': 'slow down'}, 429),
  );
  _refusal(
    'server-unavailable',
    'server is busy',
    _refuse({'error': 'unavailable'}, 503),
  );
  _refusal(
    'generic-refusal',
    'The server refused that.',
    _refuse({'error': 'teapot'}, 418),
  );
  _refusal('unreachable', "didn't answer", (request) {
    throw Exception('connection refused');
  });

  reviewCases(
    'auth-sign-in',
    state: 'address-error',
    body: (tester, viewport) => _signIn(
      tester,
      viewport,
      'auth-sign-in',
      'address-error',
      act: (tester, handles) async {
        await typeInto(tester, 'Server', 'not a url');
        await typeInto(tester, 'Username', 'alice');
        await typeInto(tester, 'Password', 'hunter2');
        await tester.tap(_button('Sign in'));
        await settleReview(tester);
        expect(
          find.text('That does not look like a server address.'),
          findsOneWidget,
        );
      },
    ),
  );

  final withIdentity = {...modernVersion, 'identity': identityA};
  _probe(
    'identity-chip-confirmed',
    withIdentity,
    pinnedKey: identityA['public_key']! as String,
  );
  _probe(
    'identity-chip-mismatch',
    withIdentity,
    pinnedKey: 'a-completely-different-key',
  );

  // An old, invite-only, push-less server that offers neither report nor block fails every check at once.
  _probe(
    'probe-notices-stacked',
    const {
      'name': 'slim-m',
      'version': '0.14.2',
      'protocol': 1,
      'invite_required': true,
      'push_enabled': false,
      'capabilities': <String>[],
    },
    extra: [pendingInviteProvider.overrideWith((ref) => 'DEADCODE1')],
  );

  reviewCases(
    'auth-sign-in',
    state: 'session-ended',
    body: (tester, viewport) => _signIn(
      tester,
      viewport,
      'auth-sign-in',
      'session-ended',
      extra: [
        sessionProvider.overrideWithValue(
          api.SessionStore()
            ..clear(reason: 'credentials rejected; the stored pair was spent'),
        ),
      ],
    ),
  );

  reviewCases(
    'auth-sign-in',
    state: 'share-waiting',
    body: (tester, viewport) => _signIn(
      tester,
      viewport,
      'auth-sign-in',
      'share-waiting',
      extra: [
        pendingShareProvider.overrideWith(
          (ref) => const PendingShare(
            IncomingShare(text: 'https://example.com/a-long-read-worth-saving'),
          ),
        ),
      ],
    ),
  );

  _registerCase(
    'username-taken',
    auth: _refuse({'error': 'taken'}, 409),
    act: (tester, handles) async {
      await typeInto(tester, 'Username', 'alice');
      await typeInto(tester, 'Password', 'hunter2-hunter2');
      await tester.tap(_button('Create account'));
      await settleReview(tester);
      expect(find.text('That username is already taken.'), findsOneWidget);
    },
  );

  _registerCase(
    'bad-request',
    auth: _refuse({'error': _errorStrings.passwordLengthError}, 400),
    act: (tester, handles) async {
      await typeInto(tester, 'Username', 'alice');
      await typeInto(tester, 'Password', 'short');
      await tester.tap(_button('Create account'));
      await settleReview(tester);
      expect(
        find.text(sentenceCase(_errorStrings.passwordLengthError)),
        findsOneWidget,
      );
    },
  );

  _registerCase(
    'invite-required',
    version: _claimedVersion,
    invite: false,
    act: (tester, handles) async {
      await tapLabel(tester, 'Create an account instead');
      expect(
        find.textContaining('Joining needs an invite code'),
        findsOneWidget,
      );
    },
  );

  _registerCase(
    'claim',
    version: const {...modernVersion, 'claimed': false},
    invite: false,
  );

  // A held code is spent with the signup, so the invite-required wording is withheld.
  _registerCase('invite-redeem', version: _claimedVersion);
}
