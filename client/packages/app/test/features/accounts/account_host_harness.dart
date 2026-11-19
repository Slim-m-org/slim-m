// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A host over real containers whose stores are in-memory and whose services
/// are inert, for the account tests that need several accounts at once.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_host.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_restore.dart';
import 'package:slimm_app/src/features/accounts/providers/account_slot.dart';
import 'package:slimm_app/src/features/accounts/providers/account_store.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/sync_controller.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_sync.dart';
import '../../support/fake_voice.dart';

/// 'first.example' is shown as 'First', as an admin-chosen name would be.
String _nameOf(String host) =>
    host[0].toUpperCase() + host.substring(1, host.indexOf('.'));

/// Stands in for a call on one container: set it to put that account in a call.
final testCallProvider = StateProvider<VoiceFlags>((ref) => const VoiceFlags());

const connectedCall = VoiceFlags(state: VoiceSessionState.connected);

/// The controller state whose flags are [f], so synchronous selects off the controller see the call too.
VoiceState _callState(VoiceFlags f) => VoiceState(
  channelId: f.channelId,
  state: f.state,
  joining: f.joining,
  rejoining: f.rejoining,
  reconnecting: f.reconnecting,
  microphoneEnabled: f.microphoneEnabled,
  cameraEnabled: f.cameraEnabled,
  cameraPending: f.cameraPending,
  screenSharing: f.screenSharing,
  awaitingBroadcast: f.awaitingBroadcast,
  shareAudio: f.shareAudio,
  canPublish: f.canPublish,
  joinedMuted: f.joinedMuted,
  deafened: f.deafened,
  error: f.error,
  retryable: f.retryable,
  connectedAt: f.connectedAt,
  recap: f.recap,
  justLeftChannelId: f.justLeftChannelId,
  justLeftAt: f.justLeftAt,
);

FakeVoiceController _testCall(Ref ref) {
  final voice = FakeVoiceController(
    ref,
    initial: _callState(ref.read(testCallProvider)),
  );
  ref.listen(testCallProvider, (_, f) => voice.set(_callState(f)));
  return voice;
}

String sessionJson(String userId) =>
    '{"user_id":"$userId","access_token":"a-$userId","refresh_token":"r-$userId","access_expires_at":0}';

class AccountHarness {
  AccountHarness({InMemoryKeyStore? keys, this.extraOverrides = const []})
    : keys = keys ?? InMemoryKeyStore() {
    store = AccountStore(this.keys);
    host = AccountHost(
      store: store,
      createContainer: _container,
      startServices: (_) async {},
      onActivate: (runtime) => onActivate(runtime),
      readSession: (r) => restoreAccountSession(store, r),
      signOutRuntime: (r) async {
        r.container.read(sessionProvider).clear();
      },
    );
  }

  final InMemoryKeyStore keys;
  final List<Override> extraOverrides;

  /// What putting an account on screen waits on; a test can make it slow.
  Future<void> Function(AccountRuntime runtime) onActivate = (_) async {};
  late final AccountStore store;
  late final AccountHost host;
  final databases = <SlimmDatabase>[];

  /// The message store of the account filed under [origin].
  final storesByFile = <String, MessageStore>{};

  ProviderContainer _container(AccountSlot slot) => ProviderContainer(
    overrides: [
      ...extraOverrides,
      keyStoreProvider.overrideWithValue(keys),
      accountSlotProvider.overrideWithValue(slot),
      accountHostProvider.overrideWith((ref) => host),
      syncControllerProvider.overrideWith((ref) => NoopSyncController(ref)),
      voiceControllerProvider.overrideWith(_testCall),
      serverInfoProvider.overrideWith(
        (ref) async => api.Version(
          name: 'slim-m',
          version: '1',
          protocol: 1,
          spaceName: _nameOf(ref.read(serverUrlProvider).host),
        ),
      ),
      storeProvider.overrideWith((ref) async {
        final file = ref.read(accountSlotProvider)!.databaseFile;
        return storesByFile.putIfAbsent(file, () {
          final db = SlimmDatabase(NativeDatabase.memory());
          databases.add(db);
          return MessageStore(db);
        });
      }),
    ],
  );

  /// Writes an account with a stored session, as a previous run would have.
  Future<Account> seed(
    String server, {
    String? user,
    bool active = false,
  }) async {
    final account = Account.forServer(
      Uri.parse(server),
      dbFile: server.contains('first') ? legacyDatabaseFile : null,
    );
    final index = await store.load();
    await store.save(
      AccountIndex(
        accounts: [...index.accounts, account],
        activeOrigin: active ? account.origin : index.activeOrigin,
      ),
    );
    if (user != null) await store.writeSession(account, sessionJson(user));
    return account;
  }

  /// Boots like main: the first container, then the index.
  Future<void> boot() async {
    host.createFirst();
    await host.start();
    await pumpEventQueueTimes();
  }

  Future<void> dispose() async {
    host.dispose();
    for (final r in List.of(host.accounts)) {
      r.container.dispose();
    }
    for (final db in databases) {
      await db.close();
    }
  }
}

Future<void> pumpEventQueueTimes([int times = 20]) async {
  for (var i = 0; i < times; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}
