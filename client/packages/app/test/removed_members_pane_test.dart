// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Behavioural coverage for the removed members pane.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/member_presence.dart'
    show membersProvider;
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/screens/admin/removed_members_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

class _Log {
  final requests = <String>[];
  int removedGets = 0;
  int memberGets = 0;
  int restoreStatus = 204;
}

Future<_Log> _pump(WidgetTester tester, {required int perms}) async {
  final log = _Log();
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      myPermissionsProvider.overrideWithValue(perms),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((r) async {
            log.requests.add('${r.method} ${r.url.path}');
            if (r.method == 'GET' && r.url.path == '/members/removed') {
              log.removedGets++;
              return _json([
                {
                  'user_id': 'u-2',
                  'username': 'bob',
                  'display_name': 'Bob',
                  'removed_at': 0,
                  'reason': 'spam',
                },
              ]);
            }
            if (r.method == 'GET' && r.url.path == '/members') {
              log.memberGets++;
              return _json([]);
            }
            if (r.method == 'DELETE' && r.url.path == '/members/u-2/removal') {
              return log.restoreStatus == 204
                  ? http.Response('', 204)
                  : _json({'error': 'nope'}, log.restoreStatus);
            }
            if (r.method == 'DELETE' && r.url.path == '/members/u-2/account') {
              return http.Response('', 204);
            }
            return _json({}, 404);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  // keep membersProvider subscribed so an invalidate triggers a refetch
  container.listen(membersProvider, (_, _) {});
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: const Scaffold(body: RemovedMembersPane()),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return log;
}

void main() {
  testWidgets('Let back in restores and refetches removals and members', (
    tester,
  ) async {
    final log = await _pump(tester, perms: Perm.banMembers);
    expect(log.removedGets, 1);
    final membersBefore = log.memberGets;
    await tester.tap(find.text('Let back in'));
    await tester.pumpAndSettle();
    expect(log.requests, contains('DELETE /members/u-2/removal'));
    expect(log.removedGets, 2, reason: 'removals list refetched');
    expect(
      log.memberGets,
      greaterThan(membersBefore),
      reason: 'members list refetched',
    );
  });

  testWidgets('Delete needs ADMINISTRATOR', (tester) async {
    await _pump(tester, perms: Perm.banMembers);
    expect(find.text('Let back in'), findsOneWidget);
    expect(find.text('Delete'), findsNothing);
  });

  testWidgets('Delete confirms first; cancel sends nothing', (tester) async {
    final log = await _pump(tester, perms: Perm.administrator);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Bob?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(log.requests.where((r) => r.contains('/account')), isEmpty);
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(log.requests, contains('DELETE /members/u-2/account'));
    expect(log.removedGets, 2);
  });

  testWidgets('a failed restore renders inline and refetches nothing', (
    tester,
  ) async {
    final log = await _pump(tester, perms: Perm.banMembers);
    log.restoreStatus = 500;
    await tester.tap(find.text('Let back in'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not let Bob back in'), findsOneWidget);
    expect(log.removedGets, 1);
  });
}
