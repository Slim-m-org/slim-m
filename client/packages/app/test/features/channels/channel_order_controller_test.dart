// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for `ChannelOrderController`: the arrangement renders the instant a
/// drag completes, and only the round trip decides whether it sticks.
/// `category_order_controller_test.dart` is the sibling file covering
/// `CategoryOrderController`, split out once this file crossed the
/// 300-line review budget - its N-independent-requests shape needs its own
/// partial-failure case this file's channel tests have no equivalent of.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' hide Channel;
import 'package:slimm_app/src/features/channels/providers/channel_order_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import '../../support/fake_api.dart';

const _tokens = TokenPair(
  userId: 'user-1',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

Map<String, dynamic> _channelJson(String id, String name, int position) => {
  'id': id,
  'name': name,
  'kind': 'text',
  'created_at': 0,
  'position': position,
};

/// One flat group, `categoryId: null` - the shape most of these tests need,
/// since they are about the request/response round trip rather than
/// category placement.
List<ChannelOrderGroup> _flat(List<String> channelIds) => [
  ChannelOrderGroup(categoryId: null, channelIds: channelIds),
];

ProviderContainer _container(
  FutureOr<http.Response> Function(http.Request) handler,
) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      mockApiOverride((request) async => handler(request)),
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
    'the requested arrangement renders before the request answers',
    () async {
      final container = _container(
        (request) => http.Response(
          jsonEncode([_channelJson('b', 'b', 0), _channelJson('a', 'a', 1)]),
          200,
        ),
      );
      final controller = container.read(
        channelOrderControllerProvider.notifier,
      );

      final future = controller.reorder(_flat(['b', 'a']));
      final pending = container
          .read(channelOrderControllerProvider)
          .pendingOrder;
      expect(
        pending,
        isNotNull,
        reason:
            'the drag already happened; nothing should wait for the server '
            'to say so before the rail reflects it',
      );
      expect(pending!.single.categoryId, isNull);
      expect(pending.single.channelIds, ['b', 'a']);

      await future;
      expect(container.read(channelOrderControllerProvider).pendingOrder, null);
      expect(container.read(channelOrderControllerProvider).error, null);
    },
  );

  test(
    'a successful reorder persists the confirmed positions locally',
    () async {
      final container = _container(
        (request) => http.Response(
          jsonEncode([_channelJson('b', 'b', 0), _channelJson('a', 'a', 1)]),
          200,
        ),
      );
      final controller = container.read(
        channelOrderControllerProvider.notifier,
      );

      await controller.reorder(_flat(['b', 'a']));

      final store = await container.read(storeProvider.future);
      final rows = await store.allChannels();
      expect(rows.map((c) => c.id), ['b', 'a']);
      expect(rows.map((c) => c.position), [0, 1]);
    },
  );

  test('a refused reorder reverts to nothing pending and shows why', () async {
    final container = _container(
      (request) => http.Response(
        jsonEncode({'error': 'missing live channel(s): c'}),
        400,
      ),
    );
    final controller = container.read(channelOrderControllerProvider.notifier);

    await controller.reorder(_flat(['a', 'b']));

    final state = container.read(channelOrderControllerProvider);
    expect(
      state.pendingOrder,
      null,
      reason:
          'a refusal must not leave the rail claiming an order that was '
          'never applied',
    );
    expect(state.error, contains('Missing live channel(s): c'));
  });

  test('retry resubmits the same arrangement that last failed', () async {
    var calls = 0;
    final container = _container((request) {
      calls++;
      if (calls == 1) {
        return http.Response(jsonEncode({'error': 'nope'}), 400);
      }
      return http.Response(
        jsonEncode([_channelJson('a', 'a', 0), _channelJson('b', 'b', 1)]),
        200,
      );
    });
    final controller = container.read(channelOrderControllerProvider.notifier);

    await controller.reorder(_flat(['a', 'b']));
    expect(container.read(channelOrderControllerProvider).error, isNotNull);

    await controller.retry();
    expect(calls, 2);
    expect(container.read(channelOrderControllerProvider).error, null);
  });

  test('dismiss clears a failure without retrying', () async {
    final container = _container(
      (request) => http.Response(jsonEncode({'error': 'nope'}), 400),
    );
    final controller = container.read(channelOrderControllerProvider.notifier);

    await controller.reorder(_flat(['a', 'b']));
    expect(container.read(channelOrderControllerProvider).error, isNotNull);

    controller.dismiss();
    expect(container.read(channelOrderControllerProvider).error, null);
  });

  test('a stale reorder response does not overwrite a newer one that already '
      'landed', () async {
    final gate1 = Completer<void>();
    final gate2 = Completer<void>();
    var callIndex = 0;
    final container = _container((request) async {
      final index = callIndex++;
      if (index == 0) {
        await gate1.future;
        return http.Response(
          jsonEncode([_channelJson('a', 'a', 0), _channelJson('b', 'b', 1)]),
          200,
        );
      }
      await gate2.future;
      return http.Response(
        jsonEncode([_channelJson('c', 'c', 0), _channelJson('d', 'd', 1)]),
        200,
      );
    });
    final controller = container.read(channelOrderControllerProvider.notifier);

    final firstCall = controller.reorder(_flat(['a', 'b']));
    // Lets the first drag's request reach the mock before the second fires.
    await Future<void>.delayed(Duration.zero);
    final secondCall = controller.reorder(_flat(['c', 'd']));

    // The newer, second drag resolves first.
    gate2.complete();
    await secondCall;
    expect(container.read(channelOrderControllerProvider).pendingOrder, null);

    // The stale first response settles after it.
    gate1.complete();
    await firstCall;

    final store = await container.read(storeProvider.future);
    final rows = await store.allChannels();
    expect(
      rows.map((c) => c.id),
      ['c', 'd'],
      reason:
          'the stale first response must not overwrite the newer '
          'arrangement the second drag already confirmed',
    );
    expect(
      container.read(channelOrderControllerProvider).pendingOrder,
      null,
      reason:
          'a stale response settling after the newer one must not reopen '
          'pending state either',
    );
  });

  test(
    'a stale reorder response does not clear a still-pending newer reorder',
    () async {
      final gate1 = Completer<void>();
      var callIndex = 0;
      final container = _container((request) async {
        final index = callIndex++;
        if (index == 0) {
          await gate1.future;
          return http.Response(
            jsonEncode([_channelJson('a', 'a', 0), _channelJson('b', 'b', 1)]),
            200,
          );
        }
        // The second drag's own request never resolves in this test.
        return Completer<http.Response>().future;
      });
      final controller = container.read(
        channelOrderControllerProvider.notifier,
      );

      final firstCall = controller.reorder(_flat(['a', 'b']));
      await Future<void>.delayed(Duration.zero);
      unawaited(controller.reorder(_flat(['c', 'd'])));
      await Future<void>.delayed(Duration.zero);

      gate1.complete();
      await firstCall;

      expect(
        container
            .read(channelOrderControllerProvider)
            .pendingOrder
            ?.single
            .channelIds,
        ['c', 'd'],
        reason:
            'the stale response for the earlier drag must not clear the '
            'still-in-flight newer one',
      );
    },
  );
}
