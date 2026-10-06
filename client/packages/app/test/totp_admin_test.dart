// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The administrator's two TOTP surfaces: clearing somebody's factor, and
/// choosing what the deployment asks for.
///
/// What the clear sheet is tested for is mostly what it says before it acts.
/// The act itself is one DELETE; the part that can go wrong is an administrator
/// pressing it without being told that it signs the member out everywhere and
/// is recorded against their own name, which is the trade decision 0048 makes
/// deliberately.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/widgets/clear_totp_sheet.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/widgets/totp_policy_row.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = api.TokenPair(
  userId: 'admin-1',
  accessToken: 'access-1',
  refreshToken: 'refresh-1',
  accessExpiresAt: 0,
);

class _Server {
  _Server({this.totpPolicy = 'optional'});

  final String totpPolicy;
  final List<String> calls = [];
  final List<Map<String, dynamic>> patches = [];

  MockClient get client => MockClient((request) async {
    final path = request.url.path;
    calls.add('${request.method} $path');
    final json = {'content-type': 'application/json'};
    if (request.method == 'PATCH' && path == '/space/settings') {
      final body = jsonDecode(request.body) as Map<String, dynamic>;
      patches.add(body);
      return http.Response(
        jsonEncode({
          'join_policy': body['join_policy'] ?? 'invite',
          'totp_policy': body['totp_policy'] ?? totpPolicy,
        }),
        200,
        headers: json,
      );
    }
    return switch ((request.method, path)) {
      ('GET', '/space/settings') => http.Response(
        jsonEncode({'join_policy': 'invite', 'totp_policy': totpPolicy}),
        200,
        headers: json,
      ),
      ('DELETE', '/admin/users/user-9/totp') => http.Response('', 204),
      _ => http.Response('{}', 404, headers: json),
    };
  });
}

Future<void> _pump(WidgetTester tester, _Server server, Widget body) async {
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
        home: Scaffold(body: SingleChildScrollView(child: body)),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the clear sheet says what it costs before it does anything', (
    tester,
  ) async {
    final server = _Server();
    await _pump(
      tester,
      server,
      Builder(
        builder: (context) => AppButton(
          label: 'open',
          onPressed: () => showClearTotpSheet(
            context,
            subjectId: 'user-9',
            subjectName: 'Ada',
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Clear two-factor for Ada'), findsOneWidget);
    expect(
      find.textContaining('signs them out on every device'),
      findsOneWidget,
    );
    expect(
      find.textContaining('recorded in the moderation log'),
      findsOneWidget,
      reason: 'an administrator has to know this is not a quiet act',
    );
    expect(
      server.calls.any((c) => c.startsWith('DELETE')),
      isFalse,
      reason: 'opening the sheet must not clear anything',
    );
  });

  testWidgets('clearing takes a second press and then says it is done', (
    tester,
  ) async {
    final server = _Server();
    await _pump(
      tester,
      server,
      Builder(
        builder: (context) => AppButton(
          label: 'open',
          onPressed: () => showClearTotpSheet(
            context,
            subjectId: 'user-9',
            subjectName: 'Ada',
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(AppButton, 'Clear it'));
    await tester.pumpAndSettle();

    expect(server.calls, contains('DELETE /admin/users/user-9/totp'));
    expect(find.textContaining('Their password alone'), findsOneWidget);
  });

  testWidgets('the policy row shows the deployment choice', (tester) async {
    await _pump(
      tester,
      _Server(totpPolicy: 'required_for_elevated'),
      const TotpPolicyRow(),
    );
    expect(find.text('Expected of admins and moderators'), findsOneWidget);
  });

  /// `off` is worded as "nobody new" because it does not turn an existing factor
  /// off, and a label saying otherwise is a lie an operator would act on.
  testWidgets('off is worded as stopping new enrolments, not as off', (
    tester,
  ) async {
    await _pump(tester, _Server(totpPolicy: 'off'), const TotpPolicyRow());
    expect(find.text('Nobody new can turn it on'), findsOneWidget);
  });

  /// The row sends only its own field, so a join policy another admin changed
  /// after this screen loaded cannot be written back from a stale snapshot.
  testWidgets('changing the policy sends no join policy at all', (
    tester,
  ) async {
    final server = _Server();
    await _pump(tester, server, const TotpPolicyRow());

    await tester.tap(find.text('Anyone who wants to'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Nobody new can turn it on'));
    await tester.pumpAndSettle();

    expect(server.patches, hasLength(1));
    expect(server.patches.single, {'totp_policy': 'off'});
  });

  /// An unrecognised policy from a newer server must not read as `off`, which
  /// would hide the enrolment screen from somebody being asked to enrol.
  test('an unknown policy parses as optional', () {
    expect(api.TotpPolicy.parse('something-new'), api.TotpPolicy.optional);
    expect(api.TotpPolicy.parse('off'), api.TotpPolicy.off);
    expect(
      api.TotpPolicy.parse('required_for_elevated'),
      api.TotpPolicy.requiredForElevated,
    );
  });

  /// A server that predates the field must not be read as having turned it off.
  test('a settings body with no totp_policy reads as optional', () {
    final settings = api.SpaceSettings.fromJson({'join_policy': 'invite'});
    expect(settings.totpPolicy, api.TotpPolicy.optional);
    expect(settings.joinPolicy, api.JoinPolicy.invite);
  });
}
