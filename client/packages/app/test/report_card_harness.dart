// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Shared fixtures for `report_card_test.dart` and
/// `report_card_actions_test.dart`: a report/profile/`/me` JSON builder, and
/// [pumpReports], which mounts a real [ReportsScreen] over a fake transport
/// and records every request it saw.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/routing/routes.dart';
import 'package:slimm_app/src/screens/admin/reports_screen.dart';
import 'package:slimm_data/data.dart' hide Channel, Message;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';

const tokens = TokenPair(
  userId: 'mod-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String reportJson({
  required String id,
  required String subjectKind,
  required String subjectId,
  String? reporterId,
  String? channelId,
  String? snapshot,
  String? subjectAuthorId,
  String reason = 'this is not okay',
  int? channelPermissions,
}) => jsonEncode({
  'id': id,
  'reporter_id': reporterId,
  'subject_kind': subjectKind,
  'subject_id': subjectId,
  'channel_id': channelId,
  'reason': reason,
  'snapshot': snapshot,
  'subject_author_id': subjectAuthorId,
  'created_at': 0,
  'channel_permissions': channelPermissions,
});

String profileJson(String id, String displayName) => jsonEncode({
  'id': id,
  'username': displayName.toLowerCase(),
  'display_name': displayName,
  'created_at': 0,
});

String meJson(int permissions) => jsonEncode({
  'id': 'mod-1',
  'username': 'mod',
  'display_name': 'Mod',
  'created_at': 0,
  'permissions': permissions,
});

/// One request the fake transport saw, for asserting a quick action reached
/// the endpoint it should have (and, just as importantly, that it did not
/// reach one it should not have before a confirmation).
class Call {
  const Call(this.method, this.path);
  final String method;
  final String path;

  @override
  bool operator ==(Object other) =>
      other is Call && other.method == method && other.path == path;

  @override
  int get hashCode => Object.hash(method, path);

  @override
  String toString() => '$method $path';
}

class Harness {
  const Harness(this.container, this.calls);
  final ProviderContainer container;
  final List<Call> calls;
}

/// Stands in for the real [SyncController], which otherwise schedules a real
/// retry timer the moment it sees a signed-in session; see
/// `channel_history_harness.dart`'s own copy of this same seam.
class _NoopSyncController extends SyncController {
  _NoopSyncController(super.ref);

  @override
  Future<void> start() async {
    state = SyncStatus.live;
  }
}

/// Answers `GET /reports`, `GET /users` and `GET /me` from the fixtures
/// given, and a permissive default for everything else so a quick action's
/// write reaches the fake transport rather than a 404 - every such request is
/// still recorded in [Harness.calls] for the test to assert on.
///
/// [router] absent (the default) mounts a bare [ReportsScreen]; passed, it is
/// used as-is, so a test that needs a real jump target can mount a stub
/// channel route alongside it.
Future<Harness> pumpReports(
  WidgetTester tester, {
  required List<String> reports,
  List<String> history = const [],
  Map<String, String> profiles = const {},
  int permissions = 0,
  SlimmDatabase? db,
  GoRouter? router,
  List<Override> overrides = const [],
}) async {
  final calls = <Call>[];
  final container = ProviderContainer(
    overrides: [
      ...overrides,
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: tokens)),
      if (db != null)
        storeProvider.overrideWith((ref) async => MessageStore(db)),
      syncControllerProvider.overrideWith((ref) => _NoopSyncController(ref)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            calls.add(Call(request.method, request.url.path));
            if (request.method == 'GET' && request.url.path == '/reports') {
              return http.Response(
                '[${reports.join(',')}]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' &&
                request.url.path == '/reports/history') {
              return http.Response(
                '[${history.join(',')}]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/users') {
              final ids = request.url.queryParameters['ids']!.split(',');
              final found = [
                for (final id in ids)
                  if (profiles[id] case final name?) profileJson(id, name),
              ];
              return http.Response(
                '[${found.join(',')}]',
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'GET' && request.url.path == '/me') {
              return http.Response(
                meJson(permissions),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            if (request.method == 'PUT' &&
                request.url.path.endsWith('/timeout')) {
              return http.Response(
                jsonEncode({'until': 1}),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return http.Response(
              '{}',
              200,
              headers: {'content-type': 'application/json'},
            );
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);

  final app = router != null
      ? MaterialApp.router(
          theme: buildTheme(Brightness.light, AppTokens.light),
          routerConfig: router,
        )
      : MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const ReportsScreen(),
        );

  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: app),
  );
  await tester.pumpAndSettle();
  return Harness(container, calls);
}

/// A minimal router: `/` mounts [ReportsScreen], and the channel pattern
/// mounts a stub naming the id it got, exactly like
/// `pinned_messages_sheet_test.dart`'s own router - a jump only has to prove
/// it reached the right channel, not render a real one.
GoRouter reportsRouter() => GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(path: '/', builder: (context, state) => const ReportsScreen()),
    GoRoute(
      path: Routes.channelPattern,
      builder: (context, state) =>
          Text('channel ${state.pathParameters['channelId']}'),
    ),
  ],
);
