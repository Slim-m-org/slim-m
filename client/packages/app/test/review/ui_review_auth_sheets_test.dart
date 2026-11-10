// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two code-entry sheets: spending an admin's reset code, and the
/// two-factor code prompt in each place it is asked for. Phone and desktop,
/// dark and light; both are `showAppSheet`, a bottom sheet under 600 and a
/// centred dialog above it.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/screens/reset_password_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_code_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_failures.dart';
import 'package:slimm_app/src/providers/providers.dart';

import '../support/mock_app_version.dart';
import 'review_auth_support.dart';
import 'review_support.dart';

final _server = Uri.parse(authServer);

Future<void> _reset(
  WidgetTester tester,
  String viewport,
  String state, {
  http.Response Function(http.Request)? reset,
  Completer<void>? hold,
  ReviewAct? afterOpen,
}) => reviewOverlay(
  tester,
  surface: 'sheet-reset-password',
  state: state,
  viewport: viewport,
  route: '/sign-in',
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore()),
    ...authOverrides(ScriptedServer(reset: reset, resetHold: hold)),
  ],
  open: (context, ref) => showResetPasswordSheet(context, _server),
  afterOpen: afterOpen,
);

ReviewAct _fillReset(String code, String password, {bool submit = true}) =>
    (tester, handles) async {
      await typeInto(tester, 'Reset code', code);
      await typeInto(tester, 'New password', password);
      if (submit) await tapLabel(tester, 'Set new password');
    };

/// Where each two-factor prompt is opened from, with the copy it passes.
typedef _Prompt = ({
  String route,
  String title,
  String description,
  String submit,
  bool dangerous,
});

const _signInPrompt = (
  route: '/sign-in',
  title: 'Enter your code',
  description: 'Enter a code from your authenticator, or a recovery code.',
  submit: 'Sign in',
  dangerous: false,
);

const _recoveryPrompt = (
  route: '/settings',
  title: 'New recovery codes',
  description: 'Enter a code; your current recovery codes will stop working.',
  submit: 'Replace codes',
  dangerous: false,
);

const _disablePrompt = (
  route: '/settings',
  title: 'Turn off two-factor authentication',
  description: 'Enter a code from your authenticator, or a recovery code.',
  submit: 'Turn off',
  dangerous: true,
);

Future<void> _totp(
  WidgetTester tester,
  String viewport,
  String state,
  _Prompt prompt, {
  api.ApiException? refusal,
  bool typeCode = false,
}) => reviewOverlay(
  tester,
  surface: 'sheet-totp-code',
  state: state,
  viewport: viewport,
  route: prompt.route,
  overrides: [
    sessionProvider.overrideWithValue(api.SessionStore()),
    ...authOverrides(ScriptedServer()),
  ],
  open: (context, ref) => showTotpCodeSheet(
    context,
    title: prompt.title,
    description: prompt.description,
    submitLabel: prompt.submit,
    dangerous: prompt.dangerous,
    onSubmit: (code) async => refusal == null
        ? null
        : totpCodeFailure(refusal, 'verify the two-factor code'),
  ),
  afterOpen: (tester, handles) async {
    if (!typeCode) return;
    await typeInto(tester, 'Authentication code', '123 456');
    // The sign-in screen under the sheet has a button of the same name, drawn first.
    await tester.tap(find.text(prompt.submit).last);
    await settleReview(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);
  setUpAll(mockAppVersion);

  reviewCases(
    'sheet-reset-password',
    state: 'empty',
    body: (tester, viewport) => _reset(tester, viewport, 'empty'),
  );

  reviewCases(
    'sheet-reset-password',
    state: 'code-rejected',
    body: (tester, viewport) => _reset(
      tester,
      viewport,
      'code-rejected',
      reset: (request) =>
          jsonResponse({'error': 'that reset code cannot be used'}, 400),
      afterOpen: _fillReset('K7QX-29PM-4TDA', 'a-long-enough-password'),
    ),
  );

  // The sheet has no confirm field, so the one password refusal it can show is the length rule.
  reviewCases(
    'sheet-reset-password',
    state: 'password-too-short',
    body: (tester, viewport) => _reset(
      tester,
      viewport,
      'password-too-short',
      afterOpen: _fillReset('K7QX-29PM-4TDA', 'short'),
    ),
  );

  reviewCases(
    'sheet-reset-password',
    state: 'busy',
    body: (tester, viewport) {
      final hold = Completer<void>();
      return whileHolding(
        tester,
        hold,
        () => _reset(
          tester,
          viewport,
          'busy',
          hold: hold,
          afterOpen: (tester, handles) async {
            await reduceMotion(tester, handles);
            await _fillReset('K7QX-29PM-4TDA', 'a-long-enough-password')(
              tester,
              handles,
            );
          },
        ),
      );
    },
  );

  reviewCases(
    'sheet-totp-code',
    state: 'sign-in',
    body: (tester, viewport) =>
        _totp(tester, viewport, 'sign-in', _signInPrompt),
  );

  reviewCases(
    'sheet-totp-code',
    state: 'recovery-code',
    body: (tester, viewport) =>
        _totp(tester, viewport, 'recovery-code', _recoveryPrompt),
  );

  reviewCases(
    'sheet-totp-code',
    state: 'wrong-code',
    body: (tester, viewport) => _totp(
      tester,
      viewport,
      'wrong-code',
      _signInPrompt,
      typeCode: true,
      refusal: const api.BadRequestException('invalid code'),
    ),
  );

  reviewCases(
    'sheet-totp-code',
    state: 'rate-limited',
    body: (tester, viewport) => _totp(
      tester,
      viewport,
      'rate-limited',
      _signInPrompt,
      typeCode: true,
      refusal: const api.RateLimitedException('slow down'),
    ),
  );

  reviewCases(
    'sheet-totp-code',
    state: 'disable',
    body: (tester, viewport) =>
        _totp(tester, viewport, 'disable', _disablePrompt),
  );
}
