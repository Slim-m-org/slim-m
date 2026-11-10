// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The join flow's front door: onboarding opened from the account switcher,
/// and the invite dialog in every state it can be left in. Phone and desktop,
/// dark and light, one mount each.
///
/// Every state here is reached by driving `OnboardingScreen` the way a person
/// does, against a scripted server (`review_auth_support.dart`): none of them is
/// a `show*` one-shot a registry could open.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/deep_links.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';

import '../support/mock_app_version.dart';
import '../support/onboarding_error_strings.dart';
import 'review_auth_support.dart';
import 'review_support.dart';

final _errorStrings = OnboardingErrorStrings.load();

const _lamplight = {
  'usable': true,
  'community': {
    'name': 'Lamplight',
    'member_count': 142,
    'invited_by': 'Grace Hopper',
    'uses_remaining': 5,
    'description': 'A small place for the game night crowd.',
  },
};

Future<void> _invite(
  WidgetTester tester,
  String viewport,
  String state, {
  ScriptedServer? server,
  List<Override> extra = const [],
  ReviewAct? act,
}) => reviewWidget(
  tester,
  surface: 'dialog-onboarding-invite',
  state: state,
  viewport: viewport,
  build: onboardingScreen,
  overrides: [...authOverrides(server ?? ScriptedServer()), ...extra],
  act: act,
);

/// Opens the dialog, fills both fields, ticks the terms and presses Continue.
ReviewAct _submitInvite({
  String address = authServer,
  String code = 'DEADCODE1',
  bool accept = true,
  bool submit = true,
}) => (tester, handles) async {
  await tapLabel(tester, 'I have an invite');
  await typeInto(tester, 'Server', address);
  await typeInto(tester, 'Invite code', code);
  if (accept) await tapLabel(tester, termsLabel);
  if (submit) await tapLabel(tester, 'Continue');
};

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  reviewCases(
    'auth-onboarding',
    state: 'add-server',
    body: (tester, viewport) => reviewWidget(
      tester,
      surface: 'auth-onboarding',
      state: 'add-server',
      viewport: viewport,
      build: onboardingScreen,
      overrides: [
        ...authOverrides(ScriptedServer()),
        accountsSnapshotProvider.overrideWithValue(
          const AccountsSnapshot(canCancelAdd: true),
        ),
      ],
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'empty',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'empty',
      act: (tester, _) => tapLabel(tester, 'I have an invite'),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'prefilled',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'prefilled',
      extra: [
        tappedInviteProvider.overrideWith(
          (ref) => (server: Uri.parse(authServer), code: 'DEADCODE1'),
        ),
      ],
      act: (tester, _) => settleReview(tester),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'terms-unaccepted',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'terms-unaccepted',
      act: _submitInvite(accept: false, submit: false),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'checking',
    body: (tester, viewport) {
      final hold = Completer<void>();
      return whileHolding(
        tester,
        hold,
        () => _invite(
          tester,
          viewport,
          'checking',
          server: ScriptedServer(hold: hold),
          act: _submitInvite(),
        ),
      );
    },
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'code-unusable',
    body: (tester, viewport) =>
        _invite(tester, viewport, 'code-unusable', act: _submitInvite()),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'address-error',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'address-error',
      act: _submitInvite(address: 'not a url'),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'scheme-refused',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'scheme-refused',
      act: _submitInvite(address: 'http://chat.example.com'),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'unreachable',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'unreachable',
      server: ScriptedServer(checkFails: true),
      act: _submitInvite(),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'server-refused',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'server-refused',
      server: ScriptedServer(
        checkBody: {'error': _errorStrings.internalError},
        checkStatus: 500,
      ),
      act: _submitInvite(),
    ),
  );

  reviewCases(
    'dialog-onboarding-invite',
    state: 'landing',
    body: (tester, viewport) => _invite(
      tester,
      viewport,
      'landing',
      server: ScriptedServer(checkBody: _lamplight),
      act: _submitInvite(),
    ),
  );
}
