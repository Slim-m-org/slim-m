// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The app as the soak harness mounts it: the real root, router, shell and
/// account host, over one fake community per account.
library;

import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/widgets/account_root.dart';
import 'package:slimm_app/main.dart' show SlimMApp;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_restore.dart';
import 'package:slimm_app/src/features/accounts/providers/account_services.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/features/members/providers/presence_activity_reporter.dart';
import 'package:slimm_app/src/features/settings/providers/notification_sound_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_app/src/push/providers/push_channel_providers.dart';
import 'package:slimm_app/src/routing/router.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_platform/testing.dart';

import '../support/fake_mic_preview.dart' show quietMicPreview;
import '../support/fake_sound_player.dart';
import '../support/fake_voice.dart';
import 'soak_census.dart';
import 'soak_sync.dart';
import 'soak_world.dart';

class SoakApp {
  SoakApp({required int accounts, required int seed, int members = 500}) {
    for (var i = 0; i < accounts; i++) {
      final name = 's$i';
      worlds['https://$name.example'] = SoakWorld(
        name: name,
        seed: seed + i,
        members: members,
      );
    }
    store = AccountStore(keys);
    host = AccountHost(
      store: store,
      createContainer: _container,
      startServices: (r) async => startAccountServices(r.container),
      onActivate: (_) async {},
      readSession: (r) => restoreAccountSession(store, r),
      signOutRuntime: (r) => signOutVia(r.container.read),
    );
  }

  final keys = InMemoryKeyStore();
  final worlds = <String, SoakWorld>{};
  final liveListeners = OriginCensus();
  final labels = ProviderLabels();

  /// Counts desktop notifications without remembering them.
  final notifications = _CountedNotifications();
  final _databases = <String, SlimmDatabase>{};
  late final AccountStore store;
  late final AccountHost host;

  List<String> get origins => worlds.keys.toList();

  ProviderContainer _container(AccountSlot slot) => ProviderContainer(
    observers: [labels],
    overrides: [
      keyStoreProvider.overrideWithValue(keys),
      accountSlotProvider.overrideWithValue(slot),
      accountHostProvider.overrideWith((ref) => host),
      syncControllerProvider.overrideWith(
        (ref) => SoakSyncController(ref, liveListeners),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => FakeVoiceController(ref, recording: true),
      ),
      apiProvider.overrideWith((ref) {
        final server = ref.watch(serverUrlProvider);
        final client = api.SlimmApi(
          baseUrl: server,
          session: ref.read(sessionProvider),
          httpClient: worlds[originOf(server)]?.client(),
        );
        ref.onDispose(client.close);
        return client;
      }),
      databaseProvider.overrideWith(
        (ref) => _databases.putIfAbsent(
          slot.databaseFile,
          () => SlimmDatabase(NativeDatabase.memory()),
        ),
      ),
      notificationSoundControllerProvider.overrideWith(
        (ref) => NotificationSoundController(ref, player: SilentSoundPlayer()),
      ),
      quietMicPreview,
      // The real one polls the host's idle time on a process-wide timer.
      systemIdleProvider.overrideWithValue(null),
      localNotificationsProvider.overrideWithValue(notifications),
      taskbarAttentionProvider.overrideWithValue(_QuietTaskbar()),
    ],
  );

  AccountRuntime runtime(String origin) => host.runtimeFor(origin)!;

  SoakSyncController sync(String origin) =>
      runtime(origin).container.read(syncControllerProvider.notifier)
          as SoakSyncController;

  FakeVoiceController voice(String origin) =>
      runtime(origin).container.read(voiceControllerProvider.notifier)
          as FakeVoiceController;

  /// Files every account as a previous run would have left it, then boots like main.
  Future<void> boot(WidgetTester tester, {int seededHistory = 60}) async {
    SharedPreferences.setMockInitialValues(const {});
    final accounts = <Account>[];
    for (final origin in origins) {
      final account = Account.forServer(
        Uri.parse(origin),
        dbFile: origin == origins.first ? legacyDatabaseFile : null,
      );
      accounts.add(account);
      final self = worlds[origin]!.selfId;
      await store.writeSession(
        account,
        '{"user_id":"$self","access_token":"a","refresh_token":"r","access_expires_at":0}',
      );
    }
    await store.save(
      AccountIndex(accounts: accounts, activeOrigin: accounts.first.origin),
    );
    final first = host.createFirst();
    await host.start();
    startAccountServices(first);
    await tester.pump();
    for (final origin in origins) {
      final world = worlds[origin]!..seedHistory(seededHistory);
      final messages = await runtime(
        origin,
      ).container.read(storeProvider.future);
      await messages.upsertChannels(world.channels);
      await messages.replaceCategories(world.categories);
    }
    await tester.pumpWidget(AccountRoot(host: host, app: const SlimMApp()));
    await tester.pump(const Duration(seconds: 1));
  }

  void go(String origin, String location) =>
      runtime(origin).container.read(routerProvider).go(location);

  Future<void> dispose(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    host.dispose();
    for (final r in List.of(host.accounts)) {
      r.container.dispose();
    }
    await tester.pump(const Duration(seconds: 1));
    for (final db in _databases.values) {
      await db.close();
    }
  }
}

class _CountedNotifications implements LocalNotifications {
  var shown = 0;

  @override
  Future<void> show(
    String text, {
    required LocalAlertChannel channel,
    String? title,
    String? payload,
    int? id,
  }) async => shown++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _QuietTaskbar implements TaskbarAttention {
  @override
  Future<void> flash() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> setBadge(int count) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
