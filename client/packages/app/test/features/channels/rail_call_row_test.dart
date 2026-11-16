// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's call row for a call another community's account holds: the
/// row is drawn from that account's own container, so its channel, its timer,
/// its Leave, and the bar's mic and deafen all belong to the call that is live.
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/accounts/providers/account.dart';
import 'package:slimm_app/src/features/accounts/providers/account_providers.dart';
import 'package:slimm_app/src/features/accounts/providers/account_unread.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_call_pill.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/server_info.dart';
import 'package:slimm_data/data.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import '../../ui_snapshot_support.dart';
import '../voice/voice_controller_harness.dart';

final _call = VoiceState(
  channelId: 'c-lounge',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(const Duration(minutes: 3)),
);

/// Another community's account: its own store, its own name, and a live call.
Future<({ProviderContainer container, SlimmDatabase db})> _other() async {
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
        (ref) => FixedVoiceController(ref, _call),
      ),
    ],
  );
  final store = await container.read(storeProvider.future);
  await store.upsertChannels(const [
    api.Channel(id: 'c-lounge', name: 'lounge', kind: 'voice', createdAt: 0),
  ]);
  return (container: container, db: db);
}

typedef _Fixture = ({ProviderContainer container, SlimmDatabase db});

/// This community, with [other]'s account in a call elsewhere.
Future<_Fixture> _here(_Fixture other) {
  final entry = AccountEntry(
    account: Account.forServer(Uri.parse('https://beta.example')),
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
    ],
  );
}

const _footer = SizedBox(
  width: 264,
  child: RailUserFooter(activeChannelId: 'c-general'),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('a call in another community names it, and its Leave ends that '
      "community's call", (tester) async {
    final other = (await tester.runAsync(_other))!;
    final here = await _here(other);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: here.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          // The pill scopes the other account's container too, as in the app.
          home: const Scaffold(
            body: Stack(
              children: [
                AccountCallPill(),
                Align(alignment: Alignment.bottomLeft, child: _footer),
              ],
            ),
          ),
        ),
      ),
    );
    await pumpFrames(tester, frames: 20);

    final row = find.byKey(railCallRowKey);
    expect(row, findsOneWidget);
    expect(find.descendant(of: row, matching: find.text('lounge')), findsOne);
    expect(
      find.descendant(of: row, matching: find.text('Beta · ')),
      findsOneWidget,
      reason: 'the community leads the second line',
    );
    expect(
      find.bySemanticsLabel('Mute'),
      findsOneWidget,
      reason: "mic and deafen drive the call that is live, in its own account",
    );

    await tester.tap(find.bySemanticsLabel('Mute'));
    await pumpFrames(tester);
    expect(tester.takeException(), isNull);
    expect(
      find.bySemanticsLabel('Unmute'),
      findsOneWidget,
      reason: "the toggle follows the other account's own call",
    );

    await tester.tap(find.bySemanticsLabel('Leave call'));
    await pumpFrames(tester);
    expect(
      other.container.read(voiceControllerProvider).state,
      VoiceSessionState.idle,
    );

    await teardownFixture(tester, here.container, here.db);
    other.container.dispose();
    await tester.runAsync(other.db.close);
  });

  testWidgets("the call pill steps aside while the rail's row shows the "
      'same call', (tester) async {
    final other = (await tester.runAsync(_other))!;
    final here = await _here(other);
    final pill = find.byKey(AccountCallPill.pillKey);
    // The rail before the pill, the order appChromeBuilder mounts them in.
    Future<void> show({required bool rail, bool onScreen = true}) =>
        tester.pumpWidget(
          UncontrolledProviderScope(
            container: here.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: Scaffold(
                body: Stack(
                  children: [
                    if (rail)
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: TickerMode(enabled: onScreen, child: _footer),
                      ),
                    const Positioned.fill(child: AccountCallPill()),
                  ],
                ),
              ),
            ),
          ),
        );

    await show(rail: true);
    expect(pill, findsNothing, reason: 'not even for the first frame');
    await pumpFrames(tester, frames: 20);
    expect(find.byKey(railCallRowKey), findsOneWidget);
    expect(pill, findsNothing);

    await show(rail: true, onScreen: false);
    await pumpFrames(tester);
    expect(
      pill,
      findsOneWidget,
      reason: 'a route pushed over the rail keeps its row mounted, unseen',
    );

    await show(rail: false);
    await pumpFrames(tester);
    expect(pill, findsOneWidget, reason: 'with no rail it is the way back');

    await show(rail: true);
    await pumpFrames(tester);
    expect(pill, findsNothing);

    await teardownFixture(tester, here.container, here.db);
    other.container.dispose();
    await tester.runAsync(other.db.close);
  });
}
