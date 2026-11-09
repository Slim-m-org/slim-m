// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `ChannelSearchController`, driven straight off a
/// `ProviderContainer` with no widget tree: whether a search filters a
/// blocked author, and whether a 403 is told apart from a genuinely empty
/// result. Both go through `searchChannelMessages`
/// (`providers/message_search.dart`), the helper the command palette's own
/// message search also calls, so removing the filter from that one place
/// breaks both callers rather than just one - see `command_palette_test.dart`
/// for the other half of that guarantee.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _harness({
  List<String> blocked = const [],
  Future<http.Response> Function(http.Request)? searchHandler,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.url.path == '/blocks') {
          return http.Response(jsonEncode(blocked), 200);
        }
        if (request.url.path.endsWith('/messages/search')) {
          if (searchHandler != null) return searchHandler(request);
          return http.Response(jsonEncode(<Object>[]), 200);
        }
        throw StateError('unexpected request in this test: ${request.url}');
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Map<String, dynamic> _hit(String id, String authorId, String content) => {
  'id': id,
  'channel_id': 'ch1',
  'author_id': authorId,
  'author_display_name': authorId,
  'seq': 1,
  'content': content,
  'created_at': 0,
  'edited_at': null,
};

/// The provider is autoDispose, so a test that outlives one await must listen.
ChannelSearchController _held(ProviderContainer container) {
  container.listen(channelSearchProvider('ch1'), (_, _) {});
  return container.read(channelSearchProvider('ch1').notifier);
}

void main() {
  test('a blocked author is absent from channel search results', () async {
    final container = _harness(
      blocked: ['pest'],
      searchHandler: (request) async => http.Response(
        jsonEncode([
          _hit('m1', 'pest', 'from a pest'),
          _hit('m2', 'other', 'from a friend'),
        ]),
        200,
      ),
    );

    // Settle blocks first, the order a real launch already guarantees.
    await container.read(blocksProvider.notifier).refresh();
    await container.read(channelSearchProvider('ch1').notifier).run('from');

    final state = container.read(channelSearchProvider('ch1'));
    expect(state.results?.map((m) => m.content), [
      'from a friend',
    ], reason: 'a second search path is still a search path');
  });

  test('a 403 is reported as forbidden, not as an empty result', () async {
    final container = _harness(
      searchHandler: (request) async =>
          http.Response(jsonEncode({'error': 'denied'}), 403),
    );

    await container.read(channelSearchProvider('ch1').notifier).run('from');

    final state = container.read(channelSearchProvider('ch1'));
    expect(state.failed, isTrue);
    expect(state.forbidden, isTrue);
    expect(state.results, isNull);
  });

  test(
    'a late reply for an older query does not replace the newer one',
    () async {
      final replies = <String, Completer<http.Response>>{};
      final container = _harness(
        searchHandler: (request) =>
            (replies[request.url.queryParameters['q']!] = Completer()).future,
      );
      final controller = _held(container);

      final dep = controller.run('dep');
      await Future<void>.delayed(Duration.zero);
      final deploy = controller.run('deploy');
      await Future<void>.delayed(Duration.zero);
      replies['deploy']!.complete(
        http.Response(jsonEncode([_hit('m2', 'other', 'deploy done')]), 200),
      );
      await deploy;
      replies['dep']!.complete(
        http.Response(jsonEncode([_hit('m1', 'other', 'depend on it')]), 200),
      );
      await dep;

      final state = container.read(channelSearchProvider('ch1'));
      expect(state.query, 'deploy');
      expect(state.results?.map((m) => m.content), ['deploy done']);
    },
  );

  test(
    'a reply that lands after the panel was closed leaves it closed',
    () async {
      final reply = Completer<http.Response>();
      final container = _harness(searchHandler: (request) => reply.future);
      final controller = _held(container)..toggle();

      final pending = controller.run('late');
      await Future<void>.delayed(Duration.zero);
      controller.toggle();
      reply.complete(
        http.Response(jsonEncode([_hit('m1', 'other', 'late')]), 200),
      );
      await pending;

      final state = container.read(channelSearchProvider('ch1'));
      expect(state.open, isFalse);
      expect(state.query, isNull);
      expect(state.results, isNull);
    },
  );

  test('clearing the field drops the reply still in flight', () async {
    final reply = Completer<http.Response>();
    final container = _harness(searchHandler: (request) => reply.future);
    final controller = _held(container)..toggle();

    final pending = controller.run('abc');
    await Future<void>.delayed(Duration.zero);
    await controller.run('  ');
    reply.complete(
      http.Response(jsonEncode([_hit('m1', 'other', 'abc')]), 200),
    );
    await pending;

    final state = container.read(channelSearchProvider('ch1'));
    expect(state.open, isTrue);
    expect(state.query, isNull);
    expect(state.results, isNull);
  });

  test('the previous hits stay up while a newer query loads', () async {
    final reply = Completer<http.Response>();
    var calls = 0;
    final container = _harness(
      searchHandler: (request) {
        if (calls++ == 0) {
          return Future.value(
            http.Response(jsonEncode([_hit('m1', 'other', 'first')]), 200),
          );
        }
        return reply.future;
      },
    );
    final controller = _held(container);
    await controller.run('first');

    final pending = controller.run('second');
    await Future<void>.delayed(Duration.zero);

    final mid = container.read(channelSearchProvider('ch1'));
    expect(mid.loading, isTrue);
    expect(mid.results?.map((m) => m.content), ['first']);
    reply.complete(http.Response(jsonEncode(<Object>[]), 200));
    await pending;
  });

  test('typing sends one request once the field has been still', () {
    fakeAsync((async) {
      final queries = <String>[];
      final container = _harness(
        searchHandler: (request) async {
          queries.add(request.url.queryParameters['q']!);
          return http.Response(jsonEncode(<Object>[]), 200);
        },
      );
      final controller = _held(container);

      for (final typed in ['d', 'de', 'dep', 'depl']) {
        controller.queryChanged(typed);
        async.elapse(const Duration(milliseconds: 50));
      }
      expect(queries, isEmpty, reason: 'every key restarts the wait');

      async.elapse(channelSearchDebounce);
      async.flushMicrotasks();
      expect(queries, ['depl']);
    });
  });

  test('closing the panel cancels a search that has not been sent yet', () {
    fakeAsync((async) {
      final queries = <String>[];
      final container = _harness(
        searchHandler: (request) async {
          queries.add(request.url.queryParameters['q']!);
          return http.Response(jsonEncode(<Object>[]), 200);
        },
      );
      final controller = _held(container)
        ..toggle()
        ..queryChanged('abc')
        ..toggle();

      async.elapse(channelSearchDebounce * 2);
      async.flushMicrotasks();

      expect(queries, isEmpty);
      expect(container.read(channelSearchProvider('ch1')).open, isFalse);
      expect(controller.mounted, isTrue);
    });
  });
}
