// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Another community's account in a live call, and the community on screen
/// seeing it as the call elsewhere, the way `AccountHost` reports it.
library;

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../features/voice/voice_controller_harness.dart';
import '../ui_snapshot_support.dart';

typedef AccountFixture = ({ProviderContainer container, SlimmDatabase db});

/// The other community's call, in its voice channel `lounge`.
final callInLounge = VoiceState(
  channelId: 'c-lounge',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(const Duration(minutes: 3)),
);

/// The community called Beta: its own store, its own name, and a live call.
Future<AccountFixture> otherCommunityInCall({
  List<Override> extraOverrides = const [],
}) async {
  final db = SlimmDatabase(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      sessionProvider.overrideWithValue(
        api.SessionStore(tokens: fixtureTokens),
      ),
      databaseProvider.overrideWith((ref) => db),
      serverInfoProvider.overrideWith(
        (ref) async => const api.Version(
          name: 'slimm-server',
          version: '0',
          protocol: 1,
          spaceName: 'Beta',
        ),
      ),
      voiceControllerProvider.overrideWith(
        (ref) => FixedVoiceController(ref, callInLounge),
      ),
      ...extraOverrides,
    ],
  );
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(const [
    api.Channel(id: 'c-lounge', name: 'lounge', kind: 'voice', createdAt: 0),
  ]);
  return (container: container, db: db);
}

/// The account [otherCommunityInCall]'s container belongs to.
final otherCommunity = Account.forServer(Uri.parse('https://beta.example'));

/// The community on screen, with [other]'s account in a call elsewhere.
Future<AccountFixture> hereWithCallElsewhere(
  AccountFixture other, {
  List<Override> extraOverrides = const [],
}) {
  final entry = AccountEntry(
    account: otherCommunity,
    container: other.container,
    active: false,
    signedIn: true,
    unread: AccountUnread.none,
    inCall: true,
  );
  return fixtureContainer(
    extraOverrides: [
      accountsSnapshotProvider.overrideWith(
        (ref) => AccountsSnapshot(entries: [entry], callElsewhere: entry),
      ),
      ...extraOverrides,
    ],
  );
}

/// Tears down the community on screen first, as the app's own order does.
Future<void> teardownBoth(
  WidgetTester tester,
  AccountFixture here,
  AccountFixture other,
) async {
  await teardownFixture(tester, here.container, here.db);
  other.container.dispose();
  await tester.runAsync(other.db.close);
}
