// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A member's own status text, shown as a caption under their name in the
/// member pane - `status_text` on `UserProfile`, rendered by `_MemberRow`
/// rather than folded into `AppListRow.meta`, since that row is deliberately
/// single-line. Split out of `member_pane_test.dart`, which already sits
/// past this repo's review budget.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

UserProfile _profile(String id, String name, {String? statusText}) =>
    UserProfile(
      id: id,
      username: name.toLowerCase(),
      displayName: name,
      createdAt: 0,
      statusText: statusText,
    );

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

SlimmApi _fakeApi(SessionStore session) => testApi((request) async {
  if (request.url.path == '/me') {
    return http.Response(
      jsonEncode({
        'id': 'self',
        'username': 'self',
        'display_name': 'Self',
        'created_at': 0,
        'permissions': 0,
      }),
      200,
    );
  }
  if (request.url.path == '/presence') {
    return http.Response('[]', 200);
  }
  throw StateError('unexpected request in this test: ${request.url}');
}, session: session);

List<Override> _overrides(List<UserProfile> members) => [
  keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
  sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
  apiProvider.overrideWith((ref) {
    final api = _fakeApi(ref.watch(sessionProvider));
    ref.onDispose(api.close);
    return api;
  }),
  membersProvider.overrideWith((ref) async => members),
  channelMembersProvider.overrideWith((ref, _) async => members),
];

Future<void> _pump(WidgetTester tester, List<UserProfile> members) async {
  final container = ProviderContainer(overrides: _overrides(members));
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: AppMemberPane(channelId: 'c1')),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('a member with a status shows it under their name', (
    tester,
  ) async {
    await _pump(tester, [_profile('1', 'Priya', statusText: 'in a meeting')]);

    expect(find.text('Priya'), findsOneWidget);
    expect(find.text('in a meeting'), findsOneWidget);
  });

  testWidgets('a member with no status shows no extra line', (tester) async {
    await _pump(tester, [_profile('1', 'Kess')]);

    expect(find.text('Kess'), findsOneWidget);
    // The absence itself is the point - no stray caption widget for a member who never set one.
  });
}
