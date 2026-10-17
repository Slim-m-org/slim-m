// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `CategoryOrderController`, split out of
/// `channel_order_controller_test.dart` for the review budget. Unlike a
/// channel reorder's single atomic request, this one fires N independent
/// `PATCH /categories/{id}` calls, so the partial-failure case below has no
/// equivalent in the channel tests.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/features/channels/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _categoryJson(String id, String name, int position) => {
  'id': id,
  'name': name,
  'position': position,
  'created_at': 0,
};

/// Routes a mocked `PATCH /categories/{id}` by the id in the path, since
/// [CategoryOrderController.reorder] fires one request per category rather
/// than [ChannelOrderController]'s single atomic one.
FutureOr<http.Response> Function(http.Request) _perCategoryHandler(
  Map<String, FutureOr<http.Response> Function(http.Request)> byId,
) => (request) {
  final id = request.url.pathSegments.last;
  final handler = byId[id];
  if (handler == null) {
    throw StateError('unexpected request for category $id');
  }
  return handler(request);
};

ProviderContainer _container(
  FutureOr<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      apiProvider.overrideWith((ref) {
        final api = SlimmApi(
          baseUrl: Uri.parse('http://localhost:8080'),
          session: ref.watch(sessionProvider),
          httpClient: MockClient((request) async => handler(request)),
        );
        ref.onDispose(api.close);
        return api;
      }),
      storeProvider.overrideWith((ref) async {
        final db = SlimmDatabase(NativeDatabase.memory());
        ref.onDispose(db.close);
        return MessageStore(db);
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'the requested arrangement renders before any request answers',
    () async {
      final gate = Completer<void>();
      final container = _container(
        _perCategoryHandler({
          'a': (_) async {
            await gate.future;
            return http.Response(jsonEncode(_categoryJson('a', 'a', 0)), 200);
          },
          'b': (_) async {
            await gate.future;
            return http.Response(jsonEncode(_categoryJson('b', 'b', 1)), 200);
          },
        }),
      );
      final controller = container.read(
        categoryOrderControllerProvider.notifier,
      );

      final future = controller.reorder(['a', 'b']);
      expect(
        container.read(categoryOrderControllerProvider).pendingOrder,
        ['a', 'b'],
        reason:
            'the drag already happened; nothing should wait for the N '
            'round trips to say so before the screen reflects it',
      );

      gate.complete();
      await future;
      expect(
        container.read(categoryOrderControllerProvider).pendingOrder,
        null,
      );
      expect(container.read(categoryOrderControllerProvider).error, null);
    },
  );

  test('a fully successful reorder persists every category\'s confirmed '
      'position locally, in the requested order', () async {
    final container = _container(
      _perCategoryHandler({
        'b': (_) async =>
            http.Response(jsonEncode(_categoryJson('b', 'b', 0)), 200),
        'a': (_) async =>
            http.Response(jsonEncode(_categoryJson('a', 'a', 1)), 200),
      }),
    );
    final controller = container.read(categoryOrderControllerProvider.notifier);

    await controller.reorder(['b', 'a']);

    final store = await container.read(storeProvider.future);
    final rows = await store.allCategories();
    expect(rows.map((c) => c.id), ['b', 'a']);
    expect(rows.map((c) => c.position), [0, 1]);
  });

  test('a category the server refuses keeps no local trace, while the ones '
      'that succeeded still apply, and the failure is reported', () async {
    final container = _container(
      _perCategoryHandler({
        'a': (_) async =>
            http.Response(jsonEncode(_categoryJson('a', 'a', 0)), 200),
        'b': (_) async => http.Response(jsonEncode({'error': 'nope'}), 400),
        'c': (_) async =>
            http.Response(jsonEncode(_categoryJson('c', 'c', 2)), 200),
      }),
    );
    final controller = container.read(categoryOrderControllerProvider.notifier);

    await controller.reorder(['a', 'b', 'c']);

    final state = container.read(categoryOrderControllerProvider);
    expect(
      state.pendingOrder,
      null,
      reason:
          'every request has settled, even though not every one '
          'succeeded',
    );
    expect(state.error, contains('Nope'));

    final store = await container.read(storeProvider.future);
    final rows = await store.allCategories();
    expect(
      rows.map((c) => c.id).toSet(),
      {'a', 'c'},
      reason:
          'the two that the server actually accepted are reflected '
          'locally; the refused one was never written',
    );
  });

  test('retry resubmits the same arrangement that last failed', () async {
    var calls = 0;
    final container = _container(
      _perCategoryHandler({
        'a': (_) async {
          calls++;
          if (calls == 1) {
            return http.Response(jsonEncode({'error': 'nope'}), 400);
          }
          return http.Response(jsonEncode(_categoryJson('a', 'a', 0)), 200);
        },
        'b': (_) async =>
            http.Response(jsonEncode(_categoryJson('b', 'b', 1)), 200),
      }),
    );
    final controller = container.read(categoryOrderControllerProvider.notifier);

    await controller.reorder(['a', 'b']);
    expect(container.read(categoryOrderControllerProvider).error, isNotNull);

    await controller.retry();
    expect(calls, 2);
    expect(container.read(categoryOrderControllerProvider).error, null);
  });

  test('dismiss clears a failure without retrying', () async {
    final container = _container(
      _perCategoryHandler({
        'a': (_) async => http.Response(jsonEncode({'error': 'nope'}), 400),
      }),
    );
    final controller = container.read(categoryOrderControllerProvider.notifier);

    await controller.reorder(['a']);
    expect(container.read(categoryOrderControllerProvider).error, isNotNull);

    controller.dismiss();
    expect(container.read(categoryOrderControllerProvider).error, null);
  });
}
