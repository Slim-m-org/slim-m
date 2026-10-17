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

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/features/channels/providers/channel_search_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

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
      apiProvider.overrideWith((ref) {
        final client = api.SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async {
            if (request.url.path == '/blocks') {
              return http.Response(jsonEncode(blocked), 200);
            }
            if (request.url.path.endsWith('/messages/search')) {
              if (searchHandler != null) return searchHandler(request);
              return http.Response(jsonEncode(<Object>[]), 200);
            }
            throw StateError('unexpected request in this test: ${request.url}');
          }),
        );
        ref.onDispose(client.close);
        return client;
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
}
