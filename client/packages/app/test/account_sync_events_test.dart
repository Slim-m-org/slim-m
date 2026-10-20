// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What another device of the same account does reaches this open client live:
/// a channel override, "Mark as unread", and a new sign-in in the devices list.
library;

import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart';
import 'package:slimm_app/src/features/channels/providers/channel_notification_overrides_controller.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/features/settings/widgets/devices_section.dart';
import 'package:slimm_data/data.dart' show MessageStore, SlimmDatabase;
import 'package:slimm_platform/testing.dart';
import 'package:slimm_test_support/slimm_test_support.dart';

const _tokens = TokenPair(
  userId: 'alice',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 4102444800000,
);

http.Response _json(Object body) => http.Response(
  jsonEncode(body),
  200,
  headers: {'content-type': 'application/json'},
);

ProviderContainer _container({
  required Stream<ServerEvent> events,
  required Future<http.Response> Function(http.Request) handle,
  MessageStore? store,
}) {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(SessionStore(tokens: _tokens)),
      liveEventsProvider.overrideWithValue(events),
      if (store != null) storeProvider.overrideWith((ref) async => store),
      apiProvider.overrideWith((ref) {
        final api = testApi(handle, session: SessionStore(tokens: _tokens));
        ref.onDispose(api.close);
        return api;
      }),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

Future<void> _settle() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

void main() {
  test(
    'an override set or cleared on another device updates this one',
    () async {
      final store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
      addTearDown(store.db.close);
      final container = _container(
        events: const Stream.empty(),
        handle: (request) async => _json(<Object>[]),
        store: store,
      );
      container.listen(channelNotificationOverridesProvider, (_, _) {});
      await _settle();
      final controller = container.read(syncControllerProvider.notifier);

      await controller.applyServerEventForTest(
        const NotificationOverrideChanged(
          channelId: 'c1',
          preference: NotificationPreference.mentions,
        ),
      );
      expect(
        container.read(channelNotificationOverridesProvider).overrideFor('c1'),
        NotificationPreference.mentions,
      );

      await controller.applyServerEventForTest(
        const NotificationOverrideChanged(channelId: 'c1', preference: null),
      );
      expect(
        container.read(channelNotificationOverridesProvider).overrideFor('c1'),
        isNull,
      );
    },
  );

  test('a new sign-in refetches the devices list', () async {
    final events = StreamController<ServerEvent>.broadcast();
    addTearDown(events.close);
    var fetched = 0;
    final container = _container(
      events: events.stream,
      handle: (request) async {
        fetched += 1;
        return _json(<Object>[]);
      },
    );
    container.listen(devicesProvider, (_, _) {});
    await container.read(devicesProvider.future);
    expect(fetched, 1);

    events.add(
      const NewDeviceSignIn(
        deviceId: 'd2',
        deviceName: 'Pixel 9',
        signedInAt: 1700000000000,
      ),
    );
    await _settle();
    expect(fetched, 2);
  });

  test('mark as unread on another device flags the channel here', () async {
    final store = MessageStore(SlimmDatabase(NativeDatabase.memory()));
    addTearDown(store.db.close);
    final container = _container(
      events: const Stream.empty(),
      handle: (request) async => http.Response('unexpected call', 500),
      store: store,
    );
    await store.upsertChannels([
      Channel.fromJson({
        'id': 'c1',
        'name': 'general',
        'kind': 'text',
        'created_at': 1000,
      }),
    ]);
    final controller = container.read(syncControllerProvider.notifier);

    await controller.applyServerEventForTest(
      const ReadStateChanged(
        channelId: 'c1',
        lastReadSeq: 0,
        manuallyUnread: true,
      ),
    );
    expect((await store.allChannels()).single.manuallyUnread, isTrue);

    await controller.applyServerEventForTest(
      const ReadStateChanged(channelId: 'c1', lastReadSeq: 0),
    );
    expect((await store.allChannels()).single.manuallyUnread, isFalse);
  });
}
