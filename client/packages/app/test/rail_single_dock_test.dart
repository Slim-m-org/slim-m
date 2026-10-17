// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail used to stack two docks when a call was live elsewhere: a call
/// bar (`VoiceStripIndicator`) directly above `RailUserFooter`, each with
/// its own mic and headset toggle. This is what fails if that regresses.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/widgets/channel_rail.dart';
import 'package:slimm_app/src/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

void main() {
  setUpAll(loadRealFonts);

  const inMainCall = VoiceState(
    channelId: 'c-main',
    state: VoiceSessionState.connected,
  );

  final timedCall = VoiceState(
    channelId: 'c-main',
    state: VoiceSessionState.connected,
    connectedAt: DateTime.now().subtract(const Duration(hours: 12)),
  );

  testWidgets(
    'a call live elsewhere renders one dock in the channel list, not two',
    (tester) async {
      final fixture = await fixtureContainer(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(ref, inMainCall),
          ),
        ],
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter('/channels'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));

      expect(
        find.byType(VoiceStripIndicator),
        findsNothing,
        reason: 'the call bar must fold into the footer, not sit above it',
      );
      expect(find.byType(RailCallSummary), findsOneWidget);
      expect(
        find.bySemanticsLabel('Mute'),
        findsOneWidget,
        reason: 'one mic toggle, not one per dock',
      );
      expect(
        find.bySemanticsLabel('Deafen'),
        findsOneWidget,
        reason: 'one headset toggle, not one per dock',
      );
      expect(find.bySemanticsLabel('Leave call'), findsOneWidget);
      expect(find.bySemanticsLabel('Personal settings'), findsOneWidget);

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  testWidgets(
    'leaving a call from elsewhere is instant, with no confirmation dialog',
    (tester) async {
      final fixture = await fixtureContainer(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => FixedVoiceController(ref, inMainCall),
          ),
        ],
      );
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp.router(
            debugShowCheckedModeBanner: false,
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            routerConfig: fixtureRouter('/channels'),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));

      await tester.tap(find.bySemanticsLabel('Leave call'));
      await tester.pump();

      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: 'the owner asked to leave instantly, not to be asked first',
      );
      expect(
        fixture.container.read(voiceControllerProvider).state,
        VoiceSessionState.idle,
        reason: 'one tap must actually leave the call, not just dismiss it',
      );

      await teardownFixture(tester, fixture.container, fixture.db);
    },
  );

  for (final width in [ChannelRail.compactWidth, 240.0, 264.0, 320.0]) {
    testWidgets('a call elsewhere keeps the footer one bar at $width wide', (
      tester,
    ) async {
      Future<double> footerHeight(VoiceState voice) async {
        final fixture = await fixtureContainer(
          extraOverrides: [
            voiceControllerProvider.overrideWith(
              (ref) => FixedVoiceController(ref, voice),
            ),
          ],
        );
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: fixture.container,
            child: MaterialApp(
              theme: buildTheme(Brightness.dark, AppTokens.dark),
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomLeft,
                  child: SizedBox(
                    width: width,
                    child: const RailUserFooter(activeChannelId: 'c-other'),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pump(const Duration(milliseconds: 350));
        final height = tester.getSize(find.byType(RailUserFooter)).height;
        if (voice.state == VoiceSessionState.connected) {
          expect(find.bySemanticsLabel('Leave call'), findsOneWidget);
          expect(
            find.byType(RailCallSummary),
            width == ChannelRail.compactWidth ? findsNothing : findsOneWidget,
            reason: 'the name line is where the call summary goes',
          );
        }
        await teardownFixture(tester, fixture.container, fixture.db);
        return height;
      }

      final idle = await footerHeight(const VoiceState());
      final inCall = await footerHeight(timedCall);
      expect(tester.takeException(), isNull, reason: 'no overflow');
      expect(inCall, idle, reason: 'a call must not grow the footer');
    });
  }
}
