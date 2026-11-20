// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `searchMessages` (`providers/message_search.dart`): that a parsed query
/// reaches the wire as the structured parameters `http::search` reads, on
/// the route its `in:` chip picks, and that a query naming nothing is
/// refused locally rather than sent.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/messages/providers/message_search.dart';
import 'package:slimm_app/src/features/messages/providers/message_search_query.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
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
        if (request.url.path.endsWith('/messages/search') ||
            request.url.path == '/search/messages') {
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
  test('every filter reaches the wire as its own param, the dates folded '
      'into one window', () async {
    Uri? seen;
    final container = _harness((request) async {
      seen = request.url;
      return http.Response(jsonEncode(<Object>[]), 200);
    });

    await searchMessages(
      container.read,
      parseSearchQuery(
        '"ship it" roadmap from:@nick mentions:ana has:image has:link '
        'pinned:true in:#general during:2026-11 after:2026-11-05',
      ),
      limit: 25,
      beforeId: 'm9',
    );

    expect(seen!.path, '/search/messages');
    expect(seen!.queryParameters, {
      'q': '"ship it" roadmap',
      'limit': '25',
      'from': 'nick',
      'mentions': 'ana',
      'in': 'general',
      'has': 'image,link',
      'pinned': 'true',
      'after_ms': '${DateTime(2026, 11, 5).millisecondsSinceEpoch}',
      'before_ms': '${DateTime(2026, 12).millisecondsSinceEpoch}',
      'before_id': 'm9',
      'include_threads': 'true',
    });
  });

  test('an in: chip picked from a list searches that channel by id', () async {
    Uri? seen;
    final container = _harness((request) async {
      seen = request.url;
      return http.Response(jsonEncode(<Object>[]), 200);
    });

    await searchMessages(
      container.read,
      parseSearchQuery(
        'hello',
        filters: const [
          SearchFilter(SearchKey.inChannel, 'Ana', channelId: 'dm1'),
        ],
      ),
    );

    expect(seen!.path, '/channels/dm1/messages/search');
    expect(seen!.queryParameters.containsKey('in'), isFalse);
    expect(seen!.queryParameters['q'], 'hello');
  });

  test('a query naming nothing is refused locally, never sent', () async {
    var requested = false;
    final container = _harness((request) async {
      requested = true;
      return http.Response(jsonEncode(<Object>[]), 200);
    });

    final result = await searchMessages(
      container.read,
      parseSearchQuery('   '),
    );

    expect(requested, isFalse);
    expect(result, isA<MessageSearchFailed>());
  });

  test('a 403 is told apart from any other failure', () async {
    final container = _harness(
      (request) async => http.Response(jsonEncode({'error': 'no'}), 403),
    );

    final result = await searchMessages(
      container.read,
      parseSearchQuery('hello'),
    );

    expect(result, isA<MessageSearchForbidden>());
  });

  test(
    'a result that lands after the caller is gone never uses its reader',
    () async {
      final gate = Completer<void>();
      final container = _harness((request) async {
        await gate.future;
        return http.Response(jsonEncode(<Object>[]), 200);
      });
      var callerGone = false;
      T read<T>(ProviderListenable<T> provider) {
        if (callerGone) {
          throw StateError('Cannot use "ref" after it was disposed.');
        }
        return container.read(provider);
      }

      final pending = searchMessages(read, parseSearchQuery('hello'));
      callerGone = true;
      gate.complete();

      expect(await pending, isA<MessageSearchHits>());
    },
  );
}
