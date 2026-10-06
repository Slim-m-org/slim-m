// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/providers/pins_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/platform.dart';

Map<String, dynamic> _pinJson(String id) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': 'author-1',
  'author_display_name': 'Priya',
  'seq': 1,
  'content': 'hello',
  'created_at': 0,
  'edited_at': null,
  'pinned_at': 0,
  'pinned_by': 'author-1',
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

void main() {
  test(
    'an older pins response landing last must not overwrite the newer one',
    () async {
      // The first GET (constructor) is slow and still lists a pin that the
      // second GET (after an unpin) no longer has.
      final first = Completer<http.Response>();
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
          sessionProvider.overrideWithValue(
            SessionStore(
              tokens: const TokenPair(
                userId: 'self',
                accessToken: 'a',
                refreshToken: 'r',
                accessExpiresAt: 0,
              ),
            ),
          ),
          apiProvider.overrideWith((ref) {
            final api = SlimmApi(
              baseUrl: Uri.parse('http://localhost:8080'),
              session: ref.watch(sessionProvider),
              httpClient: MockClient((request) async {
                if (request.url.path == '/users') return _json(<Object>[]);
                calls++;
                if (calls == 1) return first.future;
                return _json(<Object>[]);
              }),
            );
            ref.onDispose(api.close);
            return api;
          }),
        ],
      );
      addTearDown(container.dispose);
      final sub = container.listen(pinsControllerProvider('c1'), (_, __) {});
      addTearDown(sub.close);

      final notifier = container.read(pinsControllerProvider('c1').notifier);
      await notifier.refresh();
      expect(container.read(pinsControllerProvider('c1')).pinned, isEmpty);

      first.complete(_json([_pinJson('stale')]));
      await Future<void>.delayed(const Duration(milliseconds: 50));

      expect(
        container.read(pinsControllerProvider('c1')).pinned,
        isEmpty,
        reason: 'the stale first response replaced the newer, empty list',
      );
    },
  );
}
