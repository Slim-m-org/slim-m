// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The moderation queue controller, driven directly rather than through the
/// screen: `ReportsController` in reports_controller.dart owns the paging, the
/// composite cursor, the failure-preserves-what-is-on-screen rule, and the
/// generation guard that drops a stale response, and none of the report tests
/// so far render it through its real provider - they build `ReportCard` widgets
/// from hand-made data. These pin the controller's own behavior.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/members/providers/reports_controller.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// One report as the wire delivers it. `createdAt` doubles as the sort key, so
/// a page's last report is the composite cursor the next page is asked after.
Map<String, dynamic> _report(String id, int createdAt) => {
  'id': id,
  'reporter_id': 'reporter-$id',
  'subject_kind': 'message',
  'subject_id': 'msg-$id',
  'channel_id': 'chan-1',
  'reason': 'spam',
  'snapshot': 'the reported text',
  'subject_author_id': 'author-$id',
  'created_at': createdAt,
};

/// A full page's worth, ids `r0..r{n-1}` with `createdAt` equal to the index.
List<Map<String, dynamic>> _page(int n) => [
  for (var i = 0; i < n; i++) _report('r$i', i),
];

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

/// A container whose `apiProvider` answers every `/reports` GET through
/// [handler], with each request's query recorded into [seen] first.
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
      mockApiOverride((request) async {
        if (request.method == 'GET' && request.url.path == '/reports') {
          seen.add(request.url.queryParameters);
          return handler(request);
        }
        return http.Response('not found', 404);
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
    container.listen(reportsControllerProvider, (_, __) {});

    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(state.loading, isFalse);
    expect(state.error, isNull);
    expect(state.reports.map((r) => r.id), ['r0', 'r1']);
    expect(
      state.more,
      isFalse,
      reason: 'a page shorter than the size is the end',
    );

    expect(seen, hasLength(1));
    expect(seen.single.containsKey('after'), isFalse);
    expect(seen.single.containsKey('after_id'), isFalse);
    expect(seen.single['limit'], '$reportsPageSize');
  });

  test('a page filled to the size sets `more`, so the queue offers another '
      'page', () async {
    final seen = <Map<String, String>>[];
    final container = _container(
      seen,
      (_) async => _json(_page(reportsPageSize)),
    );
    container.listen(reportsControllerProvider, (_, __) {});

    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(state.reports, hasLength(reportsPageSize));
    expect(state.more, isTrue);
  });

  test('loadMore appends the next page, asking after the last report held as a '
      'composite cursor', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (request) async {
      // The first (cursor-less) call is the full first page; the second is the tail.
      final isFirst = !request.url.queryParameters.containsKey('after_id');
      return _json(isFirst ? _page(reportsPageSize) : [_report('tail', 999)]);
    });
    container.listen(reportsControllerProvider, (_, __) {});

    final controller = container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    await controller.loadMore();
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(state.reports, hasLength(reportsPageSize + 1));
    expect(state.reports.last.id, 'tail');
    expect(state.more, isFalse);

    expect(seen, hasLength(2));
    final last = _page(reportsPageSize).last;
    expect(
      seen[1]['after'],
      '${last['created_at']}',
      reason: 'the cursor is the last held report, not a page number',
    );
    expect(seen[1]['after_id'], last['id']);
  });

  test('loadMore is a no-op once a short page has ended the queue', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (_) async => _json(_page(3)));
    container.listen(reportsControllerProvider, (_, __) {});

    final controller = container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();
    expect(container.read(reportsControllerProvider).more, isFalse);

    await controller.loadMore();
    await pumpEventQueue();

    expect(
      seen,
      hasLength(1),
      reason: 'nothing more to ask for, so no request',
    );
  });

  test('a failed initial load surfaces the error with an empty queue and no '
      'false `more`', () async {
    // A refused or down first GET: a different path than a failed loadMore, with nothing on screen to preserve.
    final seen = <Map<String, String>>[];
    final container = _container(
      seen,
      (_) async => http.Response(
        jsonEncode({'error': 'you may not moderate here'}),
        403,
        headers: {'content-type': 'application/json'},
      ),
    );
    container.listen(reportsControllerProvider, (_, __) {});

    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(state.reports, isEmpty);
    expect(
      state.error,
      'Could not load the reports: you are not allowed to do that.',
    );
    expect(state.loading, isFalse);
    expect(
      state.more,
      isFalse,
      reason: 'a queue that never loaded has no next page to offer',
    );
  });

  test('a failed loadMore keeps the reports already on screen, records the '
      'error, and preserves `more`', () async {
    final seen = <Map<String, String>>[];
    final container = _container(seen, (request) async {
      if (request.url.queryParameters.containsKey('after_id')) {
        return http.Response(
          jsonEncode({'error': 'the queue is on fire'}),
          500,
          headers: {'content-type': 'application/json'},
        );
      }
      return _json(_page(reportsPageSize));
    });
    container.listen(reportsControllerProvider, (_, __) {});

    final controller = container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    await controller.loadMore();
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(
      state.reports,
      hasLength(reportsPageSize),
      reason: 'a failed load must not throw away the page already on screen',
    );
    expect(
      state.error,
      'Could not load more reports.',
      reason: 'a 500 never puts the server\'s own text in front of the user',
    );
    expect(state.loading, isFalse);
    expect(
      state.more,
      isTrue,
      reason: 'a network blip must not read as the end of the queue',
    );
  });

  test(
    'a response that arrives after a newer refresh was started is dropped',
    () async {
      final seen = <Map<String, String>>[];
      final first = Completer<void>();
      final second = Completer<void>();
      var calls = 0;

      final container = _container(seen, (_) async {
        final mine = ++calls;
        if (mine == 1) {
          await first.future;
          return _json([_report('stale', 1)]);
        }
        await second.future;
        return _json([_report('fresh', 2)]);
      });
      container.listen(reportsControllerProvider, (_, __) {});

      final controller = container.read(reportsControllerProvider.notifier);
      // The constructor's refresh issues call 1, now parked on `first`.
      await pumpEventQueue();

      unawaited(controller.refresh());
      // The second refresh issues call 2, parked on `second`.
      await pumpEventQueue();

      // Let the newer request answer first, then the older, stale one.
      second.complete();
      await pumpEventQueue();
      first.complete();
      await pumpEventQueue();

      final state = container.read(reportsControllerProvider);
      expect(
        state.reports.map((r) => r.id),
        ['fresh'],
        reason:
            'the superseded first response must never overwrite the newer one',
      );
      expect(state.loading, isFalse);
      expect(seen, hasLength(2));
    },
  );

  test('a reply the client cannot parse ends in the error state, not the '
      'spinner', () async {
    final seen = <Map<String, String>>[];
    final container = _container(
      seen,
      (_) async => _json([
        {'id': 'r0'},
      ]),
    );
    container.listen(reportsControllerProvider, (_, __) {});

    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    final state = container.read(reportsControllerProvider);
    expect(state.loading, isFalse, reason: 'the spinner must clear');
    expect(state.error, 'Could not load the reports.');
    expect(state.reports, isEmpty);
  });

  test('an unreachable server reads as a sentence, never the transport '
      'string', () async {
    final container = _container(
      [],
      (_) async => throw http.ClientException('Connection refused'),
    );
    container.listen(reportsControllerProvider, (_, __) {});

    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    expect(
      container.read(reportsControllerProvider).error,
      'Could not load the reports: the server could not be reached. '
      'Nothing was changed.',
    );
  });

  test('a live reports.changed frame refreshes the queue and keeps the '
      'pages on screen until the first one lands', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    final refreshed = Completer<void>();
    var call = 0;
    final container = _container([], (_) async {
      call++;
      if (call == 2) await refreshed.future;
      return _json(call == 1 ? _page(1) : _page(2));
    }, events: events.stream);
    container.listen(reportsControllerProvider, (_, __) {});
    container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();
    expect(container.read(reportsControllerProvider).reports, hasLength(1));

    events.add(const ReportsChanged());
    await pumpEventQueue();

    var state = container.read(reportsControllerProvider);
    expect(state.loading, isTrue);
    expect(
      state.reports,
      hasLength(1),
      reason: 'the queue stays readable while the refresh is in flight',
    );

    refreshed.complete();
    await pumpEventQueue();

    state = container.read(reportsControllerProvider);
    expect(state.loading, isFalse);
    expect(state.reports.map((r) => r.id), ['r0', 'r1']);
    expect(call, 2);
  });

  test('retrying after a failed refresh starts from the top, not after the '
      'pages already held', () async {
    final seen = <Map<String, String>>[];
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    var call = 0;
    final container = _container(seen, (_) async {
      call++;
      if (call == 2) return http.Response('unavailable', 503);
      return _json(_page(reportsPageSize));
    }, events: events.stream);
    container.listen(reportsControllerProvider, (_, __) {});
    final controller = container.read(reportsControllerProvider.notifier);
    await pumpEventQueue();

    events.add(const ReportsChanged());
    await pumpEventQueue();
    expect(container.read(reportsControllerProvider).error, isNotNull);
    expect(
      container.read(reportsControllerProvider).reports,
      hasLength(reportsPageSize),
      reason: 'a failed refresh keeps the stale queue readable',
    );

    await controller.loadMore();
    await pumpEventQueue();

    expect(seen.last.containsKey('after_id'), isFalse);
    expect(container.read(reportsControllerProvider).error, isNull);
  });
}
