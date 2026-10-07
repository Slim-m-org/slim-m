// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
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

void main() {
  test('a reports.changed refresh keeps the pages on screen while the '
      'request is in flight', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    final gate = Completer<void>();
    var calls = 0;
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
        liveEventsProvider.overrideWithValue(events.stream),
        apiProvider.overrideWith((ref) {
          final api = SlimmApi(
            baseUrl: Uri.parse('http://localhost:8080'),
            session: ref.watch(sessionProvider),
            httpClient: MockClient((request) async {
              calls++;
              final n = calls;
              if (n >= 3) await gate.future;
              final page = n == 2
                  ? [_entry('tail', 999)]
                  : [
                      for (var i = 0; i < moderationHistoryPageSize; i++)
                        _entry('a$i', i),
                    ];
              return _json(page);
            }),
          );
          ref.onDispose(api.close);
          return api;
        }),
      ],
    );
    addTearDown(container.dispose);
    container.listen(moderationHistoryControllerProvider, (_, __) {});
    final controller = container.read(
      moderationHistoryControllerProvider.notifier,
    );
    await pumpEventQueue();
    await controller.loadMore();
    await pumpEventQueue();
    expect(
      container.read(moderationHistoryControllerProvider).items,
      hasLength(moderationHistoryPageSize + 1),
    );

    // Someone files a report while the moderator reads page 2.
    events.add(const ReportsChanged());
    await pumpEventQueue();

    final during = container.read(moderationHistoryControllerProvider);
    expect(during.loading, isTrue, reason: 'the refresh request is pending');
    expect(
      during.items,
      isNotEmpty,
      reason: 'the pane swaps to a spinner and loses its scroll position',
    );
    gate.complete();
  });
}
