// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `BlocksController` driven directly: how a failed load reads to the person
/// looking at the settings pane, and what a failed block does to the edits
/// made around it.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/members/providers/blocks_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

ProviderContainer _container(
  Future<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride(handler),
    ],
  );
  addTearDown(container.dispose);
  container.listen(blocksProvider, (_, __) {});
  return container;
}

http.Response _json(Object body, [int status = 200]) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('an unreachable server reads as a sentence, never the transport '
      'string', () async {
    final container = _container(
      (_) async => throw http.ClientException('Connection refused'),
    );

    await pumpEventQueue();

    final state = container.read(blocksProvider);
    expect(state.settled, isTrue);
    expect(
      state.error,
      'Could not load the block list: the server could not be reached. '
      'Nothing was changed.',
    );
  });

  test('a reply the client cannot parse reads as a fixed sentence', () async {
    final container = _container((_) async => _json({'not': 'a list'}));

    await pumpEventQueue();

    expect(
      container.read(blocksProvider).error,
      'Could not load the block list.',
    );
  });

  test('a block that fails undoes only itself, not the block made after '
      'it', () async {
    final slowFailure = Completer<http.Response>();
    final container = _container((request) async {
      if (request.method == 'GET') return _json(<String>[]);
      if (request.url.path == '/blocks/a') return slowFailure.future;
      return http.Response('', 204);
    });
    await pumpEventQueue();
    final controller = container.read(blocksProvider.notifier);

    final blockA = controller.block('a');
    await pumpEventQueue();
    await controller.block('b');
    expect(container.read(blocksProvider).ids, {'a', 'b'});

    slowFailure.complete(_json({'error': 'nope'}, 500));
    await expectLater(blockA, throwsA(isA<ApiException>()));

    expect(container.read(blocksProvider).ids, {
      'b',
    }, reason: 'b was confirmed by the server; a failing must not unblock it');
  });

  test('an unblock that fails puts the block back', () async {
    final container = _container((request) async {
      if (request.method == 'GET') return _json(['a']);
      return _json({'error': 'nope'}, 500);
    });
    await pumpEventQueue();

    await expectLater(
      container.read(blocksProvider.notifier).unblock('a'),
      throwsA(isA<ApiException>()),
    );

    expect(container.read(blocksProvider).ids, {'a'});
  });
}
