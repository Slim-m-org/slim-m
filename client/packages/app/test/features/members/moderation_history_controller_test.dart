// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `ModerationHistoryController`'s own behavior, the same shape
/// `reports_controller_test.dart` pins for its sibling queue: the composite
/// cursor, a refused fetch surfacing as an error rather than a crash (a
/// non-holder's whole path to seeing data), and - unlike the open queue - a
/// live `reports.changed` frame refreshing the feed rather than needing a
/// manual pull.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/features/members/providers/moderation_history_controller.dart';
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

List<Map<String, dynamic>> _page(int n) => [
  for (var i = 0; i < n; i++) _entry('a$i', i),
];

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

void main() {
  test('the initial load fetches the first page with no cursor and clears '
      'loading', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (_) async => _json(_page(2)));
    container.listen(moderationHistoryControllerProvider, (_, __) {});

    container.read(moderationHistoryControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(moderationHistoryControllerProvider);
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    expect(state.items.map((i) => i.id), ['a0', 'a1']);
    expect(state.more, isFalse);

    expect(seen, hasLength(1));
    expect(seen.single.containsKey('after'), isFalse);
    expect(seen.single.containsKey('after_kind'), isFalse);
    expect(seen.single.containsKey('after_id'), isFalse);
    expect(seen.single['limit'], '$moderationHistoryPageSize');
  });

  test('a page filled to the size sets `more`', () async {
    final seen = <Map<String, String>>[];
    final container = _container(
      seen,
      (_) async => _json(_page(moderationHistoryPageSize)),
    );
    container.listen(moderationHistoryControllerProvider, (_, __) {});

    container.read(moderationHistoryControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(moderationHistoryControllerProvider);
    expect(state.items, hasLength(moderationHistoryPageSize));
    expect(state.more, isTrue);
  });

  test(
    'loadMore asks after the last item held, as its own kind and id',
    () async {
      final seen = <Map<String, String>>[];
      final container = _container(seen, (request) async {
        final isFirst = !request.url.queryParameters.containsKey('after_id');
        return _json(
          isFirst ? _page(moderationHistoryPageSize) : [_entry('tail', 999)],
        );
      });
      container.listen(moderationHistoryControllerProvider, (_, __) {});

      final controller = container.read(
        moderationHistoryControllerProvider.notifier,
      );
      await pumpEventQueue();

      await controller.loadMore();
      await pumpEventQueue();

      final state = container.read(moderationHistoryControllerProvider);
      expect(state.items, hasLength(moderationHistoryPageSize + 1));
      expect(state.items.last.id, 'tail');
      expect(state.more, isFalse);

      expect(seen, hasLength(2));
      final last = _page(moderationHistoryPageSize).last;
      expect(
        seen[1]['after'],
        '${last['created_at']}',
        reason: 'the cursor is the last held item\'s own event time',
      );
      expect(seen[1]['after_kind'], 'audit_log');
      expect(seen[1]['after_id'], last['id']);
    },
  );

  test('loadMore is a no-op once a short page has ended the feed', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (_) async => _json(_page(3)));
    container.listen(moderationHistoryControllerProvider, (_, __) {});

    final controller = container.read(
      moderationHistoryControllerProvider.notifier,
    );
    await pumpEventQueue();
    expect(container.read(moderationHistoryControllerProvider).more, isFalse);

    await controller.loadMore();
    await pumpEventQueue();

    expect(seen, hasLength(1));
  });

  test('a refused fetch (a non-holder\'s 403) surfaces the error with an '
      'empty feed rather than throwing', () async {
    final seen = <Map<String, String>>[];
    final container = _container(
      seen,
      (_) async => http.Response(
        jsonEncode({'error': 'you may not moderate here'}),
        403,
        headers: {'content-type': 'application/json'},
      ),
    );
    container.listen(moderationHistoryControllerProvider, (_, __) {});

    container.read(moderationHistoryControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(moderationHistoryControllerProvider);
    expect(state.items, isEmpty);
    expect(state.error, 'you may not moderate here');
    expect(state.loading, isFalse);
    expect(state.more, isFalse);
  });

  test('a failed loadMore keeps the items already on screen and records the '
      'error', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (request) async {
      if (request.url.queryParameters.containsKey('after_id')) {
        return http.Response(
          jsonEncode({'error': 'the feed is on fire'}),
          500,
          headers: {'content-type': 'application/json'},
        );
      }
      return _json(_page(moderationHistoryPageSize));
    });
    container.listen(moderationHistoryControllerProvider, (_, __) {});

    final controller = container.read(
      moderationHistoryControllerProvider.notifier,
    );
    await pumpEventQueue();

    await controller.loadMore();
    await pumpEventQueue();

    final state = container.read(moderationHistoryControllerProvider);
    expect(state.items, hasLength(moderationHistoryPageSize));
    expect(state.error, 'the feed is on fire');
    expect(state.more, isTrue);
  });

  test(
    'a live reports.changed frame refreshes the feed from the top',
    () async {
      final seen = <Map<String, String>>[];
      final events = StreamController<ServerEvent>.broadcast();
      addTearDown(events.close);
      var call = 0;
      final container = _container(seen, (_) async {
        call++;
        return _json(call == 1 ? _page(1) : _page(2));
      }, events: events.stream);
      container.listen(moderationHistoryControllerProvider, (_, __) {});

      container.read(moderationHistoryControllerProvider.notifier);
      await pumpEventQueue();
      expect(
        container.read(moderationHistoryControllerProvider).items,
        hasLength(1),
      );

      events.add(const ReportsChanged());
      await pumpEventQueue();

      expect(seen, hasLength(2));
      expect(
        container.read(moderationHistoryControllerProvider).items,
        hasLength(2),
        reason:
            'the live frame must trigger a fresh fetch, not just log the '
            'event',
      );
    },
  );
}
