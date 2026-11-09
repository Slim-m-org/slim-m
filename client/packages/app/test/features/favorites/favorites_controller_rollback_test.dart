// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A failed favorites change puts back only the entry it was about, and a
/// favorite added before the list ever loaded does not stand in for the list.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/favorites/providers/favorites_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';

const _tokens = api.TokenPair(
  userId: 'self',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, Object?> _gif(String id) => {
  'id': id,
  'kind': 'gif',
  'title': 'gif $id',
  'width': 100,
  'height': 100,
  'available': true,
  'created_at': 1,
};

class _Server {
  _Server(this.favorites, {this.failFirstList = false});

  final List<String> favorites;
  final bool failFirstList;
  int _lists = 0;
  final Map<String, Completer<http.Response>> _writes = {};

  Future<http.Response> handle(http.Request request) {
    final call = '${request.method} ${request.url.path}';
    if (call == 'GET /favorites') {
      if (failFirstList && _lists++ == 0) {
        return Future.value(http.Response(jsonEncode({'error': 'down'}), 500));
      }
      return Future.value(
        http.Response(jsonEncode([for (final id in favorites) _gif(id)]), 200),
      );
    }
    if (call == 'POST /favorites') {
      return Future.value(http.Response(jsonEncode(_gif('added')), 201));
    }
    return (_writes[call] = Completer<http.Response>()).future;
  }

  void accept(String call) => _writes[call]!.complete(http.Response('', 204));

  void refuse(String call) =>
      _writes[call]!.complete(http.Response(jsonEncode({'error': 'no'}), 500));
}

ProviderContainer _container(_Server server) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(api.SessionStore(tokens: _tokens)),
      mockApiOverride(server.handle),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

List<String> _ids(ProviderContainer container) => [
  for (final f
      in container.read(favoritesProvider).valueOrNull ?? <api.Favorite>[])
    f.id,
];

Future<void> _pump() => Future<void>.delayed(Duration.zero);

void main() {
  test(
    'a failed remove leaves a later remove of another entry alone',
    () async {
      final server = _Server(['A', 'B', 'C']);
      final container = _container(server);
      await container.read(favoritesProvider.future);
      final controller = container.read(favoritesProvider.notifier);

      final a = controller.remove('A');
      final aFailed = expectLater(a, throwsA(isA<api.ApiException>()));
      final b = controller.remove('B');
      await _pump();
      server.accept('DELETE /favorites/B');
      await b;
      server.refuse('DELETE /favorites/A');
      await aFailed;

      expect(_ids(container), ['A', 'C']);
    },
  );

  test('a failed move leaves a later remove of another entry alone', () async {
    final server = _Server(['A', 'B', 'C']);
    final container = _container(server);
    await container.read(favoritesProvider.future);
    final controller = container.read(favoritesProvider.notifier);

    final move = controller.move(0, 2);
    final moveFailed = expectLater(move, throwsA(isA<api.ApiException>()));
    expect(_ids(container), ['B', 'C', 'A']);
    final remove = controller.remove('C');
    await _pump();
    server.accept('DELETE /favorites/C');
    await remove;
    server.refuse('PUT /favorites/order');
    await moveFailed;

    expect(_ids(container), ['A', 'B']);
  });

  test(
    'a favorite added before the list loaded does not hide the rest',
    () async {
      final server = _Server(['X', 'Y'], failFirstList: true);
      final container = _container(server);
      container.listen(favoritesProvider, (_, _) {});
      await expectLater(
        container.read(favoritesProvider.future),
        throwsA(isA<api.ApiException>()),
      );

      await container.read(favoritesProvider.notifier).addGif('tok');
      final loaded = await container.read(favoritesProvider.future);

      expect([for (final f in loaded) f.id], ['X', 'Y']);
    },
  );
}
