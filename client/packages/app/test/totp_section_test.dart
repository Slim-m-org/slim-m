// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The two-factor section under Account & devices: what it offers in each
/// state, that enrolment cannot be completed without a code, and that the codes
/// a person gets are actually shown to them.
///
/// The sheets are driven rather than constructed directly, because the bug this
/// guards against is not a widget rendering wrong - it is a step being skipped.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/totp_section.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'user-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

String _status({
  bool enabled = false,
  bool pending = false,
  int remaining = 0,
  String policy = 'optional',
}) => jsonEncode({
  'enabled': enabled,
  'pending': pending,
  'recovery_codes_remaining': remaining,
  'policy': policy,
  'confirmed_at': enabled ? 1 : null,
});

/// The codes the fake server hands back, distinctive enough that finding one on
/// screen cannot be a coincidence.
const _codes = ['zzz-code-one', 'zzz-code-two', 'zzz-code-three'];

/// Every request the section and its sheets make, with a per-path record so a
/// test can assert what was and was not called.
class _Server {
  _Server({this.statusBody, this.confirmStatus = 200, this.passwordOk = true});

  final String? statusBody;
  final int confirmStatus;

  /// False answers enrol and confirm like a server that refuses the password.
  final bool passwordOk;
  final List<String> calls = [];

  /// The JSON body of each enrol and confirm, in order.
  final List<Map<String, dynamic>> bodies = [];

  /// The JSON body of each recovery-code reissue and disable, in order.
  final List<Map<String, dynamic>> codeBodies = [];

  MockClient get client => MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    final json = {'content-type': 'application/json'};
    if (path == '/auth/totp/enrol' || path == '/auth/totp/confirm') {
      bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
      if (!passwordOk) {
        return http.Response(
          jsonEncode({'error': 'that password is not correct'}),
          403,
          headers: json,
        );
      }
    }
    if (path == '/auth/totp/recovery-codes' || path == '/auth/totp/disable') {
      codeBodies.add(jsonDecode(request.body) as Map<String, dynamic>);
    }
    return switch ((request.method, path)) {
      ('GET', '/auth/totp') => http.Response(
        statusBody ?? _status(),
        200,
        headers: json,
      ),
      ('POST', '/auth/totp/enrol') => http.Response(
        jsonEncode({
          'secret': 'JBSWY3DPEHPK3PXP',
          'provisioning_uri':
              'otpauth://totp/demo:ada?secret=JBSWY3DPEHPK3PXP&issuer=demo',
        }),
        200,
        headers: json,
      ),
      ('POST', '/auth/totp/confirm') =>
        confirmStatus == 200
            ? http.Response(
                jsonEncode({'recovery_codes': _codes}),
                200,
                headers: json,
              )
            : http.Response(
                jsonEncode({'error': 'that code is not valid'}),
                confirmStatus,
                headers: json,
              ),
      ('POST', '/auth/totp/recovery-codes') => http.Response(
        jsonEncode({'recovery_codes': _codes}),
        200,
        headers: json,
      ),
      ('POST', '/auth/totp/disable') => http.Response('', 204),
      _ => http.Response('{}', 404, headers: json),
    };
  });
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
        home: const Scaffold(body: SingleChildScrollView(child: TotpSection())),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The sheet's submit sits below a 180px QR code, so on the default test
/// surface it starts off-screen and a bare `tap` would miss it and silently do
/// nothing. Scrolling it in first is what makes the tap real.
Future<void> _tapSubmit(WidgetTester tester, String label) async {
  final button = find.widgetWithText(AppButton, label);
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// Taps the turn-on row and gets past the password step, which is the first
/// thing the flow asks for.
Future<void> _startEnrolment(WidgetTester tester) async {
  await tester.tap(find.text('Turn on two-factor authentication'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byType(TextField), 'correct horse');
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(AppButton, 'Continue'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('an account with no factor is offered one', (tester) async {
    await _pump(tester, _Server());
    expect(find.text('Turn on two-factor authentication'), findsOneWidget);
    expect(find.text('Recovery codes'), findsNothing);
  });

  /// A half-finished setup is not the same offer: the copy has to say it was
  /// started, or somebody reads "turn on" and assumes the first attempt worked.
  testWidgets('a started-but-unconfirmed enrolment says so', (tester) async {
    await _pump(tester, _Server(statusBody: _status(pending: true)));
    expect(find.text('Finish setting up'), findsOneWidget);
    expect(find.textContaining('did not finish'), findsOneWidget);
  });

  testWidgets('an enabled factor offers its codes and a way off', (
    tester,
  ) async {
    await _pump(
      tester,
      _Server(statusBody: _status(enabled: true, remaining: 10)),
    );
    expect(find.text('Recovery codes'), findsOneWidget);
    expect(find.text('10 left'), findsOneWidget);
    expect(find.text('Turn off two-factor authentication'), findsOneWidget);
    expect(find.text('Turn on two-factor authentication'), findsNothing);
  });

  /// A count alone is not a warning. Somebody down to their last code needs to
  /// be told while replacing them is still possible.
  testWidgets('running low on recovery codes is said in words', (tester) async {
    await _pump(
      tester,
      _Server(statusBody: _status(enabled: true, remaining: 1)),
    );
    expect(find.textContaining('Only 1 recovery code left'), findsOneWidget);
  });

  testWidgets('with none left it says what that costs', (tester) async {
    await _pump(tester, _Server(statusBody: _status(enabled: true)));
    expect(find.textContaining('no recovery codes left'), findsOneWidget);
  });

  /// The operator turned it off and this member never had one, so a control
  /// that could only 403 is absent rather than shown.
  testWidgets('the section is absent when the server refuses enrolments', (
    tester,
  ) async {
    await _pump(tester, _Server(statusBody: _status(policy: 'off')));
    expect(find.text('Two-factor authentication'), findsNothing);
  });

  /// `off` must not hide the way out from somebody who already enrolled, or
  /// flipping a deployment setting strands them with a factor they cannot
  /// remove.
  testWidgets('an existing factor stays manageable when the policy is off', (
    tester,
  ) async {
    await _pump(
      tester,
      _Server(statusBody: _status(enabled: true, remaining: 5, policy: 'off')),
    );
    expect(find.text('Turn off two-factor authentication'), findsOneWidget);
  });

  /// The property the whole two-step design exists for: opening the sheet and
  /// closing it has changed nothing, so a mis-scanned code cannot lock anybody
  /// out.
  testWidgets('enrolling shows the secret and needs a code before it is on', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);

    await _startEnrolment(tester);

    expect(
      find.text('JBSWY3DPEHPK3PXP'),
      findsOneWidget,
      reason: 'the secret is shown as text, for a device with no camera',
    );
    expect(
      find.byType(QrImageView),
      findsOneWidget,
      reason: 'and as a QR code, for one with a camera',
    );
    expect(
      server.calls.contains('POST /auth/totp/confirm'),
      isFalse,
      reason: 'nothing is switched on before a code is presented',
    );

    // The submit is refused while no code has been typed.
    final turnOn = find.widgetWithText(AppButton, 'Turn on');
    expect(turnOn, findsOneWidget);
    expect(tester.widget<AppButton>(turnOn).disabled, isTrue);
  });

  testWidgets('a confirmed enrolment shows the recovery codes once', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server);
    await _startEnrolment(tester);

    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    await _tapSubmit(tester, 'Turn on');

    expect(server.calls, contains('POST /auth/totp/confirm'));
    expect(
      server.bodies,
      everyElement(containsPair('password', 'correct horse')),
      reason: 'enrol and confirm both carry the password',
    );
    for (final code in _codes) {
      expect(
        find.textContaining(code),
        findsOneWidget,
        reason: 'every recovery code has to be readable, not just the first',
      );
    }
    expect(find.textContaining('never again'), findsOneWidget);
  });

  /// A refused code keeps the sheet open on the same enrolment rather than
  /// dropping somebody back to a section that still says "turn on".
  testWidgets('a refused code leaves the enrolment sheet open', (tester) async {
    final server = _Server(confirmStatus: 400);
    await _pump(tester, server);
    await _startEnrolment(tester);

    await tester.enterText(find.byType(TextField), '000000');
    await tester.pumpAndSettle();
    await _tapSubmit(tester, 'Turn on');

    expect(find.textContaining('was not accepted'), findsOneWidget);
    expect(
      find.text('JBSWY3DPEHPK3PXP'),
      findsOneWidget,
      reason: 'the same secret is still on screen to try again against',
    );
  });

  /// A session token alone must not start an enrolment: a wrong password is
  /// told so, persistently, and the secret is never shown.
  testWidgets('a wrong password keeps the password step open with the reason', (
    tester,
  ) async {
    final server = _Server(passwordOk: false);
    await _pump(tester, server);
    await _startEnrolment(tester);

    expect(find.text('That password is not correct.'), findsOneWidget);
    expect(find.byType(AppErrorState), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('JBSWY3DPEHPK3PXP'), findsNothing);
    expect(find.widgetWithText(AppButton, 'Continue'), findsOneWidget);
  });

  testWidgets('Recovery codes replaces the set with the code typed', (
    tester,
  ) async {
    final server = _Server(statusBody: _status(enabled: true, remaining: 3));
    await _pump(tester, server);

    await tester.tap(find.text('Recovery codes'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '654321');
    await tester.pumpAndSettle();
    await _tapSubmit(tester, 'Replace codes');

    expect(server.codeBodies, [
      {'code': '654321'},
    ]);
    expect(find.textContaining(_codes.first), findsOneWidget);
  });

  testWidgets('Turn off sends the code and refreshes the status', (
    tester,
  ) async {
    final server = _Server(statusBody: _status(enabled: true, remaining: 3));
    await _pump(tester, server);

    await tester.tap(find.text('Turn off two-factor authentication'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '123456');
    await tester.pumpAndSettle();
    await _tapSubmit(tester, 'Turn off');

    expect(server.codeBodies, [
      {'code': '123456'},
    ]);
    expect(
      server.calls.where((c) => c == 'GET /auth/totp').length,
      2,
      reason: 'the section refetches its status once the factor is off',
    );
  });
}
