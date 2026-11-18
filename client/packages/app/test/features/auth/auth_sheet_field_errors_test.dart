// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The account sheets put a refusal of what was typed under the field that
/// holds it, as sign-in does; only a failure no field owns stays a boxed
/// AppErrorState.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/auth/screens/reset_password_sheet.dart';
import 'package:slimm_app/src/features/auth/widgets/change_password_sheet.dart';
import 'package:slimm_app/src/features/auth/widgets/reauth_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_code_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_failures.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';

final _server = Uri.parse('https://chat.example');

/// Mounts a button that opens a sheet through [open], and opens it.
Future<void> _open(
  WidgetTester tester,
  void Function(BuildContext context) open, {
  http.Client? client,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        probeApiProvider.overrideWithValue(
          (baseUrl) => SlimmApi(
            baseUrl: baseUrl,
            httpClient:
                client ?? MockClient((_) async => http.Response('', 204)),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => open(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await pumpFrames(tester, frames: 30);
}

Finder _field(String label) =>
    find.byWidgetPredicate((w) => w is AppInput && w.semanticLabel == label);

String? _errorUnder(WidgetTester tester, String label) =>
    tester.widget<AppInput>(_field(label)).errorText;

Finder _banner() => find.byWidgetPredicate((w) => w is AppErrorState);

Future<void> _press(WidgetTester tester, String label) async {
  await tester.tap(
    find.descendant(
      of: find.byWidgetPredicate((w) => w is AppButton),
      matching: find.text(label),
    ),
  );
  await pumpFrames(tester, frames: 20);
}

http.Client _refusingReset(String message) => MockClient(
  (request) async => http.Response(
    jsonEncode({'error': message}),
    400,
    headers: const {'content-type': 'application/json'},
  ),
);

void main() {
  group('reset password', () {
    testWidgets('an empty code is said under the code field', (tester) async {
      await _open(tester, (c) => showResetPasswordSheet(c, _server));
      await tester.enterText(_field('New password'), 'a-long-enough-pass');
      await _press(tester, 'Set new password');

      expect(_errorUnder(tester, 'Reset code'), contains('Enter the code'));
      expect(_banner(), findsNothing);
    });

    testWidgets('a short password is said under the password field', (
      tester,
    ) async {
      await _open(tester, (c) => showResetPasswordSheet(c, _server));
      await tester.enterText(_field('Reset code'), 'code-abc');
      await tester.enterText(_field('New password'), 'short');
      await _press(tester, 'Set new password');

      expect(
        _errorUnder(tester, 'New password'),
        contains('at least $kPasswordMinChars'),
      );
      expect(_banner(), findsNothing);
    });

    testWidgets('a refused code is said under the code field', (tester) async {
      await _open(
        tester,
        (c) => showResetPasswordSheet(c, _server),
        client: _refusingReset('that reset code cannot be used'),
      );
      await tester.enterText(_field('Reset code'), 'spent-code');
      await tester.enterText(_field('New password'), 'a-long-enough-pass');
      await _press(tester, 'Set new password');

      expect(_errorUnder(tester, 'Reset code'), contains('cannot be used'));
      expect(_banner(), findsNothing);
    });
  });

  testWidgets('a wrong password is said under the password field', (
    tester,
  ) async {
    await _open(
      tester,
      (c) => showReauthSheet(
        c,
        title: 'Confirm',
        description: 'Prove it.',
        submitLabel: 'Go',
        onSubmit: (password, code) async => reauthFailure(
          const ForbiddenException('the password is not correct'),
          'confirm',
        ),
      ),
    );
    await tester.enterText(_field('Your password'), 'hunter2');
    await tester.pump();
    await _press(tester, 'Go');

    expect(_errorUnder(tester, 'Your password'), contains('not correct'));
    expect(_banner(), findsNothing);
  });

  testWidgets('a rejected code is said under the code field', (tester) async {
    await _open(
      tester,
      (c) => showReauthSheet(
        c,
        title: 'Confirm',
        description: 'Prove it.',
        submitLabel: 'Go',
        askForCode: true,
        onSubmit: (password, code) async => reauthFailure(
          const BadRequestException('invalid code'),
          'confirm',
          askedForCode: true,
        ),
      ),
    );
    await tester.enterText(_field('Your password'), 'hunter2');
    await tester.enterText(_field('Authentication code'), '123456');
    await tester.pump();
    await _press(tester, 'Go');

    expect(
      _errorUnder(tester, 'Authentication code'),
      contains('not accepted'),
    );
    expect(_errorUnder(tester, 'Your password'), isNull);
    expect(_banner(), findsNothing);
  });

  testWidgets('a wrong current password is said under that field', (
    tester,
  ) async {
    await _open(
      tester,
      (c) => showChangePasswordSheet(
        c,
        askForCode: false,
        onSubmit: (current, next, code) async => reauthFailure(
          const ForbiddenException('the password is not correct'),
          'change the password',
        ),
      ),
    );
    await tester.enterText(_field('Current password'), 'old-password');
    await tester.enterText(_field('New password'), 'a-long-enough-pass');
    await tester.enterText(_field('Repeat new password'), 'a-long-enough-pass');
    await tester.pump();
    await _press(tester, 'Change password');

    expect(_errorUnder(tester, 'Current password'), contains('not correct'));
    expect(_banner(), findsNothing);
  });

  testWidgets('a refused two-factor code is said under the code field', (
    tester,
  ) async {
    await _open(
      tester,
      (c) => showTotpCodeSheet(
        c,
        title: 'Enter your code',
        description: 'From your authenticator.',
        submitLabel: 'Sign in',
        onSubmit: (code) async => totpCodeFailure(
          const BadRequestException('invalid code'),
          'verify the two-factor code',
        ),
      ),
    );
    await tester.enterText(_field('Authentication code'), '123456');
    await tester.pump();
    await _press(tester, 'Sign in');

    expect(
      _errorUnder(tester, 'Authentication code'),
      contains('not accepted'),
    );
    expect(_banner(), findsNothing);
  });

  testWidgets('a failure no field owns stays a boxed error', (tester) async {
    await _open(
      tester,
      (c) => showReauthSheet(
        c,
        title: 'Confirm',
        description: 'Prove it.',
        submitLabel: 'Go',
        onSubmit: (password, code) async =>
            reauthFailure(const RateLimitedException('slow down'), 'confirm'),
      ),
    );
    await tester.enterText(_field('Your password'), 'hunter2');
    await tester.pump();
    await _press(tester, 'Go');

    expect(_errorUnder(tester, 'Your password'), isNull);
    expect(_banner(), findsOneWidget);
  });
}
