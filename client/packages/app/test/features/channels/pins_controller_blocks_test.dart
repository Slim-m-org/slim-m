// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Pins from somebody the viewer has blocked are hidden, and follow the block
/// list as it changes rather than only as it stood when the pins were fetched.
library;

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/channels/providers/pins_controller.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _pin(String id, String author) => {
  'id': id,
  'channel_id': 'c1',
  'author_id': author,
  'author_display_name': author,
  'seq': 1,
  'content': 'pinned by $author',
  'created_at': 0,
  'edited_at': null,
  'pinned_at': 0,
  'pinned_by': author,
};

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

Future<ProviderContainer> _mount() async {
  var pinFetches = 0;
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(const Stream.empty()),
      mockApiOverride((request) async {
        final path = request.url.path;
        if (path == '/channels/c1/pins') {
          pinFetches++;
          return _json([_pin('p1', 'pest'), _pin('p2', 'friend')]);
        }
        if (path == '/blocks' && request.method == 'GET') return _json([]);
        if (path.startsWith('/blocks/')) return http.Response('', 204);
        if (path == '/users') return _json(<Object>[]);
        return _json(<Object>[]);
      }),
    ],
  );
  addTearDown(container.dispose);
  container.listen(pinsControllerProvider('c1'), (_, _) {});
  while (!container.read(blocksProvider).settled ||
      container.read(pinsControllerProvider('c1')).pinned == null) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(pinFetches, 1);
  return container;
}

List<String> _authors(ProviderContainer container) => [
  for (final p
      in container.read(pinsControllerProvider('c1')).pinned ??
          const <api.PinnedMessage>[])
    p.message.authorId ?? '',
];

void main() {
  test('blocking an author hides their pins at once', () async {
    final container = await _mount();
    expect(_authors(container), ['pest', 'friend']);

    await container.read(blocksProvider.notifier).block('pest');

    expect(_authors(container), ['friend']);
  });

  test('unblocking an author brings their pins back', () async {
    final container = await _mount();
    await container.read(blocksProvider.notifier).block('pest');
    expect(_authors(container), ['friend']);

    await container.read(blocksProvider.notifier).unblock('pest');

    expect(_authors(container), ['pest', 'friend']);
  });
}
