// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `searchChannelMessages` (`providers/message_search.dart`): that a raw
/// search-bar string is parsed and forwarded as the structured query
/// parameters `http::search` reads, and that a query which parses to
/// nothing at all is refused locally rather than sent.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_search.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _harness(
  Future<http.Response> Function(http.Request) searchHandler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride((request) async {
        if (request.url.path == '/blocks') {
          return http.Response(jsonEncode(<Object>[]), 200);
        }
        if (request.url.path.endsWith('/messages/search')) {
          return searchHandler(request);
        }
        throw StateError('unexpected request in this test: ${request.url}');
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'operators parse out of the raw text and reach the wire as their own params',
    () async {
      Map<String, String>? seen;
      final container = _harness((request) async {
        seen = request.url.queryParameters;
        return http.Response(jsonEncode(<Object>[]), 200);
      });

      await searchChannelMessages(
        container.read,
        'ch1',
        'roadmap from:nick in:general has:attachment,link '
            'after:2024-01-01 before:2024-06-15',
      );

      expect(seen, isNotNull);
      expect(seen!['q'], 'roadmap');
      expect(seen!['from'], 'nick');
      expect(seen!['in'], 'general');
      expect(seen!['has'], 'attachment,link');
      expect(seen!['after_date'], '2024-01-01');
      expect(seen!['before_date'], '2024-06-15');
    },
  );

  test('a search made entirely of operators sends no q param at all', () async {
    Map<String, String>? seen;
    final container = _harness((request) async {
      seen = request.url.queryParameters;
      return http.Response(jsonEncode(<Object>[]), 200);
    });

    await searchChannelMessages(
      container.read,
      'ch1',
      'from:nick has:attachment',
    );

    expect(seen, isNotNull);
    expect(seen!.containsKey('q'), isFalse);
    expect(seen!['from'], 'nick');
    expect(seen!['has'], 'attachment');
  });

  test('a whitespace-only query is refused locally, never sent', () async {
    var requested = false;
    final container = _harness((request) async {
      requested = true;
      return http.Response(jsonEncode(<Object>[]), 200);
    });

    final result = await searchChannelMessages(container.read, 'ch1', '   ');

    expect(requested, isFalse);
    expect(result, isA<MessageSearchFailed>());
  });
}
