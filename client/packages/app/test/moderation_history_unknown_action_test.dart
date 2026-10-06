// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The history feed with an audit row the client has no badge for. The server
/// writes sixteen kinds of action into `moderation_audit_log` (migration 0098's
/// CHECK) and `GET /reports/history` returns every one, so a bot or nickname
/// row must not cost the moderator the whole page: the History tab shows its
/// spinner while `loading` is true and no items are held.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/moderation_history_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'mod-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// One audit-log entry as the wire delivers it. `createdAt` doubles as the
/// sort key, matching `reports_controller_test.dart`'s own `_report`.
Map<String, dynamic> _entry(String id, int createdAt) => {
  'kind': 'audit_log',
  'id': id,
  'actor_id': 'actor-$id',
  'subject_id': 'subject-$id',
  'action': 'remove',
  'reason': null,
  'until': null,
  'created_at': createdAt,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container whose `apiProvider` answers every `/reports/history` GET
/// through [handler], with each request's query recorded into [seen] first,
/// and whose `liveEventsProvider` is [events] rather than a real socket.
ProviderContainer _container(
  List<Map<String, String>> seen,
  Future<http.Response> Function(http.Request) handler, {
  Stream<ServerEvent>? events,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events ?? const Stream.empty()),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.method == 'GET' &&
                request.url.path == '/reports/history') {
              seen.add(request.url.queryParameters);
              return handler(request);
            }
            return http.Response('not found', 404);
          }),
        );
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

/// Every action the server's CHECK allows beyond the five the client knows.
const _beyondModeration = [
  'bot_create',
  'bot_revoke',
  'bot_permission_grant',
  'webhook_create',
  'webhook_revoke',
  'webhook_rotate',
  'totp_cleared',
  'account_delete',
  'reset_code_issue',
  'nickname_set',
  'nickname_clear',
];

Future<ModerationHistoryState> _settle(List<Map<String, dynamic>> page) async {
  final container = _container([], (_) async => _json(page));
  container.listen(moderationHistoryControllerProvider, (_, __) {});
  container.read(moderationHistoryControllerProvider.notifier);
  await pumpEventQueue();
  return container.read(moderationHistoryControllerProvider);
}

void main() {
  test('control: a page of moderation actions loads', () async {
    final state = await _settle([_entry('a1', 2), _entry('a0', 1)]);
    expect(state.loading, isFalse, reason: 'spinner must clear');
    expect(state.items, hasLength(2));
  });

  for (final action in _beyondModeration) {
    test('an audit row with action $action does not lose the page', () async {
      final state = await _settle([
        {..._entry('a1', 2), 'action': action},
        _entry('a0', 1),
      ]);
      expect(state.loading, isFalse, reason: 'spinner must clear');
      expect(state.items, hasLength(2), reason: 'the whole page must survive');
    });
  }

  test('an action the server grows later does not lose the page', () async {
    final state = await _settle([
      {..._entry('a1', 2), 'action': 'a_future_action'},
      _entry('a0', 1),
    ]);
    expect(state.loading, isFalse, reason: 'spinner must clear');
    expect(state.items, hasLength(2));
  });

  test('a row of an unknown kind is dropped and the rest of the page '
      'survives', () async {
    final state = await _settle([
      {..._entry('a2', 3), 'kind': 'a_future_kind'},
      _entry('a1', 2),
      _entry('a0', 1),
    ]);
    expect(state.loading, isFalse, reason: 'spinner must clear');
    expect(state.items.map((i) => i.id), ['a1', 'a0']);
  });

  test('a malformed row ends in the error state, not the spinner', () async {
    final state = await _settle([
      {'kind': 'audit_log'},
    ]);
    expect(state.loading, isFalse, reason: 'spinner must clear');
    expect(state.error, isNotNull);
    expect(state.items, isEmpty);
  });
}
