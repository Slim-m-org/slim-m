// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Closing the two-factor setup sheet after the code was confirmed, and what
/// the code and password failure helpers say when the request never arrived.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/auth/widgets/reauth_sheet.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_failures.dart';
import 'package:slimm_app/src/features/settings/widgets/totp_section.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

/// Answers the status read from `enabled`, which the confirm call flips the way
/// the real server does the moment a code is accepted.
class _Server {
  bool enabled = false;
  int statusReads = 0;

  MockClient get client => MockClient((request) async {
    final json = {'content-type': 'application/json'};
    return switch ((request.method, request.url.path)) {
      ('GET', '/auth/totp') => () {
        statusReads++;
        return http.Response(
          jsonEncode({
            'enabled': enabled,
            'pending': false,
            'recovery_codes_remaining': enabled ? 10 : 0,
            'policy': 'optional',
            'confirmed_at': enabled ? 1 : null,
          }),
          200,
          headers: json,
        );
      }(),
      ('POST', '/auth/totp/enrol') => http.Response(
        jsonEncode({
          'secret': 'JBSWY3DPEHPK3PXP',
          'provisioning_uri': 'otpauth://totp/demo:ada?secret=JBSWY3DPEHPK3PXP',
        }),
        200,
        headers: json,
      ),
      ('POST', '/auth/totp/confirm') => () {
        enabled = true;
        return http.Response(
          jsonEncode({
            'recovery_codes': ['zzz-code-one', 'zzz-code-two'],
          }),
          200,
          headers: json,
        );
      }(),
      _ => http.Response('{}', 404, headers: json),
    };
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _pump(WidgetTester tester, _Server server) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final built = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: server.client,
        );
        ref.onDispose(built.close);
        return built;
      }),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: const Scaffold(
          body: SingleChildScrollView(
            child: SettingsSectionCard(children: [TotpSection()]),
          ),
        ),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _confirmEnrolment(WidgetTester tester) async {
  await tester.tap(find.text('Turn on'));
  await _settle(tester);
  await tester.enterText(
    find.byWidgetPredicate((w) => w is TextField),
    'correct horse',
  );
  await tester.pump();
  await tester.tap(find.widgetWithText(AppButton, 'Continue'));
  await _settle(tester);
  await tester.enterText(
    find.byWidgetPredicate((w) => w is TextField),
    '123456',
  );
  await tester.pump();
  final submit = find.widgetWithText(AppButton, 'Turn on').last;
  await tester.ensureVisible(submit);
  await _settle(tester);
  await tester.tap(submit);
  await _settle(tester);
}

void main() {
  testWidgets('dismissing the recovery codes without Done still shows the '
      'factor as on', (tester) async {
    final server = _Server();
    await _pump(tester, server);
    await _confirmEnrolment(tester);
    expect(find.textContaining('zzz-code-one'), findsOneWidget);

    await tester.tapAt(const Offset(4, 4));
    await _settle(tester);

    expect(find.textContaining('zzz-code-one'), findsNothing);
    expect(find.text('ON'), findsOneWidget);
    expect(find.text('Turn on'), findsNothing);
    expect(server.statusReads, 2);
  });

  group('a request that never arrived', () {
    const dropped = api.ConnectionDroppedException(
      'POST /auth/totp/confirm failed: ClientException uri=https://host/x',
    );

    test('is not told as the transport string by the code failure', () {
      final sentence = totpCodeFailure(dropped, 'turn off two-factor sign-in');
      expect(
        sentence,
        'Could not turn off two-factor sign-in: the server could not be '
        'reached. Nothing was changed.',
      );
    });

    test('is not told as the transport string by the password failure', () {
      final sentence = reauthFailure(dropped, 'change the password');
      expect(
        sentence,
        'Could not change the password: the server could not be reached. '
        'Nothing was changed.',
      );
    });

    test('a refused code keeps its own sentences', () {
      expect(
        totpCodeFailure(const api.BadRequestException('x'), 'verify'),
        startsWith('That code was not accepted.'),
      );
      expect(
        totpCodeFailure(const api.RateLimitedException('x'), 'verify'),
        startsWith('Too many incorrect codes.'),
      );
    });

    test('a conflict from the server is still told with its reason', () {
      expect(
        reauthFailure(
          const api.ConflictException(
            'two-factor authentication is already on',
          ),
          'start two-factor setup',
        ),
        'Could not start two-factor setup. Two-factor authentication is '
        'already on.',
      );
    });
  });
}
