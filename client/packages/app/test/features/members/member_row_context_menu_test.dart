// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click on a member row used to do nothing at all; a left tap
/// already opened the full profile popover (message, report, block, and
/// every moderation verb the caller holds), so the fix is reaching that
/// exact same call rather than building a second, narrower menu.
library;

import 'dart:convert';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/member_presence.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _container() => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
    mockApiOverride((request) async {
      if (request.url.path == '/me') {
        return _json({
          'id': 'self',
          'username': 'self',
          'display_name': 'Self',
          'created_at': 0,
          'permissions': 0,
        });
      }
      if (request.url.path == '/presence') return _json(const []);
      return http.Response('', 204);
    }),
    membersProvider.overrideWith(
      (ref) async => [
        const api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: 'Maya',
          createdAt: 0,
        ),
      ],
    ),
    channelMembersProvider.overrideWith(
      (ref, _) async => [
        const api.UserProfile(
          id: 'user-maya',
          username: 'maya',
          displayName: 'Maya',
          createdAt: 0,
        ),
      ],
    ),
  ],
);

Future<void> main() async {
  testWidgets('a right-click opens the same profile popover a tap does', (
    tester,
  ) async {
    final container = _container();
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
    await tester.pumpAndSettle();

    expect(
      find.text('Message'),
      findsNothing,
      reason: 'the popover must not already be open before the right-click',
    );

    await tester.tapAt(
      tester.getCenter(find.text('Maya')),
      buttons: kSecondaryButton,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();

    expect(
      find.text('Message'),
      findsOneWidget,
      reason:
          'this is the same popover a left tap opens - report and block '
          'live here too, so nothing about the menu needed rebuilding',
    );
    expect(find.text('Block'), findsOneWidget);
  });
}
