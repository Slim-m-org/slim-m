// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail used to stack two docks when a call was live elsewhere: a call
/// bar (`VoiceStripIndicator`) directly above `RailUserFooter`, each with
/// its own mic and headset toggle. This is what fails if that regresses.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_app/src/widgets/shortcut_label.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import '../voice/voice_controller_harness.dart';

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

  /// Pumps the footer alone, runs [body], then tears the fixture down.
  Future<void> withFooter(
    WidgetTester tester,
    VoiceState voice,
    Future<void> Function() body, {
    required double width,
    String activeChannelId = 'c-other',
  }) async {
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
                child: RailUserFooter(activeChannelId: activeChannelId),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await withFixtureTeardown(tester, fixture, body);
  }

  final bar = find.byKey(const Key('rail-footer-padding'));

  for (final width in [ChannelRail.compactWidth, 240.0, 264.0, 320.0]) {
    testWidgets('a call elsewhere takes its own row directly above an '
        'unchanged user bar at $width wide, Leave last over the gear', (
      tester,
    ) async {
      late double idleBar;
      await withFooter(tester, const VoiceState(), width: width, () async {
        idleBar = tester.getSize(bar).height;
        expect(find.byKey(railCallRowKey), findsNothing);
      });

      await withFooter(tester, timedCall, width: width, () async {
        expect(tester.takeException(), isNull, reason: 'no overflow');
        expect(tester.getSize(bar).height, idleBar, reason: 'same user bar');

        final row = tester.getRect(find.byKey(railCallRowKey));
        expect(
          tester.getRect(bar).top - row.bottom,
          moreOrLessEquals(AppSpacing.s4 + 1),
          reason:
              "the row sits directly on the bar: its own padding, the bar's "
              'border',
        );
        final leave = tester.getRect(find.bySemanticsLabel('Leave call'));
        expect(
          leave.center.dx,
          greaterThan(tester.getRect(find.byKey(railCallSummaryKey)).right),
          reason: 'Leave last',
        );
        expect(
          leave.center.dx,
          moreOrLessEquals(
            tester.getCenter(find.bySemanticsLabel('Personal settings')).dx,
          ),
          reason: 'Leave sits over the gear',
        );
        expect(
          tester.getCenter(find.byIcon(AppIcons.voice)).dx,
          moreOrLessEquals(
            tester.getCenter(find.bySemanticsLabel('Change your status')).dx,
          ),
          reason: 'the speaker glyph sits over the avatar',
        );
      });
    });
  }

  testWidgets('no call row for a call in the channel on screen', (
    tester,
  ) async {
    await withFooter(
      tester,
      timedCall,
      width: 264,
      activeChannelId: 'c-main',
      () async {
        expect(find.byKey(railCallRowKey), findsNothing);
        expect(find.bySemanticsLabel('Mute'), findsOneWidget);
      },
    );
  });

  testWidgets('the call row says where it goes and what Leave does', (
    tester,
  ) async {
    await withFooter(tester, timedCall, width: 264, () async {
      expect(find.byTooltip('Go to main'), findsOneWidget);
      expect(
        find.byTooltip(labelWithShortcut('Leave call', AppAction.leaveCall)),
        findsOneWidget,
      );
      for (final (label, action) in [
        ('Mute', AppAction.toggleMuteCall),
        ('Deafen', AppAction.toggleDeafenCall),
        ('Notes', AppAction.openNotes),
        ('Settings', AppAction.openSettings),
      ]) {
        expect(
          find.byTooltip(labelWithShortcut(label, action)),
          findsOneWidget,
          reason: label,
        );
      }
    });
  });

  testWidgets("a bar control's tooltip opens above the call row, never over "
      'its Leave', (tester) async {
    await withFooter(tester, timedCall, width: 264, () async {
      await tester.pump();
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      for (final (label, action) in [
        ('Settings', AppAction.openSettings),
        ('Notes', AppAction.openNotes),
        ('Mute', AppAction.toggleMuteCall),
      ]) {
        final message = labelWithShortcut(label, action);
        await gesture.moveTo(tester.getCenter(find.byTooltip(message)));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200));
        // The tip's own box, not its padded text.
        final tip = tester.getRect(
          find
              .ancestor(
                of: find.text(message),
                matching: find.byWidgetPredicate((w) => w is DecoratedBox),
              )
              .first,
        );
        final row = tester.getRect(find.byKey(railCallRowKey));
        expect(
          tip.bottom,
          lessThanOrEqualTo(row.top - AppSpacing.s4 - 1),
          reason: "$label's tooltip must clear the call row and its border",
        );
        await gesture.moveTo(Offset.zero);
        await tester.pump(const Duration(seconds: 1));
      }
      await gesture.removePointer();
    });
  });
}
