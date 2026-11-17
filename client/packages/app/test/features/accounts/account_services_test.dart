// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What every account's container runs, shown or not: a ring in a Space out
/// of view still raises the desktop call notification, and a call the app
/// restarted itself out of comes back there.
library;

import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:slimm_api/api.dart' as api;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/accounts/providers/account_services.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/voice/providers/call_restore.dart';
import 'package:slimm_app/src/providers/live_events.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/push/providers/push_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/fake_api.dart';
import '../../support/fake_sync.dart';

class _Notifications implements LocalNotifications {
  final shown = <LocalAlertChannel>[];

  @override
  Future<void> show(
    String text, {
    required LocalAlertChannel channel,
    String? title,
    String? payload,
    int? id,
  }) async => shown.add(channel);

  @override
  Future<void> cancel(LocalAlertChannel channel) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _me = api.TokenPair(
  userId: 'me',
  accessToken: 'access',
  refreshToken: 'refresh',
  accessExpiresAt: 0,
);

/// A container with inert services, as the host starts one for a Space.
ProviderContainer _space({
  required Stream<api.ServerEvent> events,
  required SlimmDatabase db,
  LocalNotifications? notifications,
  List<Override> overrides = const [],
}) => ProviderContainer(
  overrides: [
    keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
    sessionProvider.overrideWithValue(api.SessionStore(tokens: _me)),
    liveEventsProvider.overrideWithValue(events),
    if (notifications != null)
      localNotificationsProvider.overrideWithValue(notifications),
    syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
    storeProvider.overrideWith((ref) async => MessageStore(db)),
    mockApiOverride(
      (_) async => http.Response(
        '[]',
        200,
        headers: {'content-type': 'application/json'},
      ),
    ),
    ...overrides,
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'a call the app restarted itself out of comes back in a Space out of view',
    () async {
      SharedPreferences.setMockInitialValues({
        callRestoreKey: CallToRestore(
          channelId: 'voice-1',
          userId: 'me',
          at: DateTime.now(),
          muted: false,
          restart: true,
        ).encode(),
      });
      final rejoined = <String>[];
      final db = SlimmDatabase(NativeDatabase.memory());
      final container = _space(
        events: const Stream.empty(),
        db: db,
        overrides: [
          accountActiveProvider.overrideWith((ref) => false),
          restorableChannelProvider.overrideWithValue((_) async => 'Lounge'),
          rejoinRestoredCallProvider.overrideWithValue(
            (call) async => rejoined.add(call.channelId),
          ),
        ],
      );
      addTearDown(() async {
        container.dispose();
        await db.close();
      });

      startAccountServices(container);
      await pumpEventQueue();

      expect(rejoined, ['voice-1']);
    },
  );

  test(
    'a ring in a container out of view raises the call notification',
    () async {
      final events = StreamController<api.ServerEvent>.broadcast();
      final notifications = _Notifications();
      final db = SlimmDatabase(NativeDatabase.memory());
      final container = _space(
        events: events.stream,
        db: db,
        notifications: notifications,
      );
      addTearDown(() async {
        container.dispose();
        await events.close();
        await db.close();
      });

      startAccountServices(container);
      events.add(
        const api.CallRinging(
          channelId: 'c1',
          ringId: 'r1',
          callerId: 'friend',
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(notifications.shown, [LocalAlertChannel.calls]);
    },
  );
}
