// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reported by the owner: setting your own status through the avatar menu
/// did not update your own row in the member pane until something unrelated
/// (a join, a moderation event) happened to refetch the roster.
/// `membersProvider` (`providers/member_presence.dart`) is a plain
/// `FutureProvider.autoDispose` that only ever refetches on those unrelated
/// events; a `PATCH /me` never touched it. `memberProfileOverridesProvider`
/// is the fix: it patches the caller's own cached entry directly from the
/// `updateMe` response, rather than a blanket `ref.invalidate` that would
/// re-page the whole roster for a one-row change. This drives the real flow
/// end to end - open the avatar menu, submit a status, read the member pane
/// - and asserts `/members` is fetched only once, so a regression back to
/// "just invalidate the roster" would also be caught here.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/widgets/member_pane.dart';
import 'package:slimm_app/src/features/members/widgets/presence_menu.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

({ProviderContainer container, int Function() membersFetches}) _wire() {
  var membersFetches = 0;
  String? statusText;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'PATCH' && request.url.path == '/me') {
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              statusText = body['status_text'] as String?;
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'status_text': statusText,
                }),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.url.path == '/me') {
              return http.Response(
                jsonEncode({
                  'id': 'self',
                  'username': 'self',
                  'display_name': 'Self',
                  'created_at': 0,
                  'permissions': 0,
                  'status_text': statusText,
                }),
                200,
              );
            }
            if (request.url.path == '/members') {
              membersFetches++;
              return http.Response(
                jsonEncode([
                  {
                    'id': 'self',
                    'username': 'self',
                    'display_name': 'Self',
                    'created_at': 0,
                    'status_text': statusText,
                  },
                ]),
                200,
              );
            }
            if (request.url.path == '/presence') {
              return http.Response('[]', 200);
            }
            return http.Response('[]', 200);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return (container: container, membersFetches: () => membersFetches);
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  tester.view.physicalSize = const Size(800, 1400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: Scaffold(
          body: Row(
            children: [
              const SizedBox(
                width: 44,
                height: 44,
                child: PresenceMenuButton(),
              ),
              const Expanded(child: AppMemberPane(channelId: 'c1')),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'setting a status updates the caller\'s own row in the member pane '
    'without a manual refetch',
    (tester) async {
      final wired = _wire();
      await _pump(tester, wired.container);

      expect(find.text('at lunch'), findsNothing, reason: 'no status set yet');

      await tester.tap(find.bySemanticsLabel('Change your status'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'at lunch');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      expect(
        find.text('at lunch'),
        findsOneWidget,
        reason:
            'the caller\'s own member pane row must show the new status '
            'the moment the write succeeds',
      );
      expect(
        wired.membersFetches(),
        1,
        reason:
            'the fix patches the caller\'s own cached entry; it must not '
            'fall back to re-paging the whole roster',
      );
    },
  );
}
