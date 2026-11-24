// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Loading more invites is guarded: a double tap fetches one page, and a
/// page that overlaps the list adds no duplicate rows.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'admin',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

String _page(Iterable<String> codes) => jsonEncode([
  for (final code in codes)
    {
      'code': code,
      'uses': 0,
      'created_at': 0,
      'created_by': 'admin',
      'revoked': false,
      'usable': true,
    },
]);

void main() {
  test(
    'a double load-more fetches the next page once, without duplicates',
    () async {
      final second = Completer<http.Response>();
      final befores = <String?>[];
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
          mockApiOverride((request) async {
            final before = request.url.queryParameters['before'];
            befores.add(before);
            if (before == null) {
              return http.Response(
                _page([for (var i = 0; i < invitePageSize; i++) 'code-$i']),
                200,
                headers: {'content-type': 'application/json'},
              );
            }
            return second.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.listen(invitesProvider, (_, _) {});
      await container.read(invitesProvider.future);

      final notifier = container.read(invitesProvider.notifier);
      final first = notifier.loadMore();
      final again = notifier.loadMore();
      second.complete(
        http.Response(
          _page(['last-page']),
          200,
          headers: {'content-type': 'application/json'},
        ),
      );
      await Future.wait([first, again]);

      expect(befores, [null, 'code-${invitePageSize - 1}']);
      final codes = container
          .read(invitesProvider)
          .requireValue
          .items
          .map((i) => i.code)
          .toList();
      expect(codes.where((c) => c == 'last-page'), hasLength(1));
      expect(codes, hasLength(invitePageSize + 1));
    },
  );
}
