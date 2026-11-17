// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's call row for a call another community's account holds: the
/// row is drawn from that account's own container, so its channel, its timer,
/// its Leave, and the bar's mic and deafen all belong to the call that is live.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/accounts/widgets/account_call_pill.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/async_wait.dart';
import '../../support/call_elsewhere_fixture.dart';
import '../../ui_snapshot_support.dart';

const _footer = SizedBox(
  width: 264,
  child: RailUserFooter(activeChannelId: 'c-general'),
);

void main() {
  setUpAll(loadRealFonts);

  testWidgets('Tab reaches the call summary and Enter opens the call', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        home: Scaffold(
          body: RailCallSummary(
            channelName: 'lounge',
            connectedAt: null,
            screenSharing: false,
            onOpen: () async => opened++,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused != null &&
          find
              .descendant(
                of: find.byWidgetPredicate((w) => w is RailCallSummary),
                matching: find.byElementPredicate((e) => e == focused),
              )
              .evaluate()
              .isNotEmpty,
      isTrue,
      reason: 'Tab reaches the summary',
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(opened, 1);
  });

  testWidgets('a call in another community names it, and its Leave ends that '
      "community's call", (tester) async {
    final other = (await tester.runAsync(otherCommunityInCall))!;
    final here = await hereWithCallElsewhere(other);
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
      find.descendant(of: row, matching: find.text('Beta')),
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

    await teardownBoth(tester, here, other);
  });

  testWidgets("the call pill steps aside while the rail's row shows the "
      'same call', (tester) async {
    final other = (await tester.runAsync(otherCommunityInCall))!;
    final here = await hereWithCallElsewhere(other);
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

    await teardownBoth(tester, here, other);
  });
}
