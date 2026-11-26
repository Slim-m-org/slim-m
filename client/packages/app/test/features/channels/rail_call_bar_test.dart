// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The rail's call bar: no speaker glyph, mute and deafen and screen share
/// beside Leave, and the profile row under it without a second mute and deafen.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail.dart';
import 'package:slimm_app/src/features/channels/widgets/channel_rail_frame.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import '../../ui_snapshot_support.dart';
import '../voice/voice_call_controls_harness.dart' show InertSession;

class _Recorded extends FakeVoiceController {
  _Recorded(super.ref, VoiceState state, InertSession session)
    : super(initial: state, session: session, recording: true);
}

const _share = ScreenShareSource(id: 's1', name: 'Screen 1');

final _live = VoiceState(
  channelId: 'c-main',
  state: VoiceSessionState.connected,
  connectedAt: DateTime.now().subtract(const Duration(minutes: 34)),
);

final _sharing = _live.copyWith(screenSharing: true);

void main() {
  setUpAll(loadRealFonts);

  final bar = find.byKey(const Key('rail-footer-padding'));
  final callRow = find.byKey(railCallRowKey);

  Future<void> withRail(
    WidgetTester tester,
    VoiceState voice,
    Future<void> Function(InertSession session, _Recorded controller) body, {
    double width = 248,
    bool touch = false,
    InertSession? session,
  }) async {
    final inert =
        session ??
        InertSession(needsSource: true, sources: Future.value([_share]));
    late _Recorded controller;
    final fixture = await fixtureContainer(
      extraOverrides: [
        voiceControllerProvider.overrideWith(
          (ref) => controller = _Recorded(ref, voice, inert),
        ),
      ],
    );
    Widget footer() => SizedBox(
      width: width,
      child: const RailUserFooter(activeChannelId: 'c-other'),
    );
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: fixture.container,
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomLeft,
              child: touch
                  ? AppTouchTargets(enabled: true, child: footer())
                  : footer(),
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 350));
    await withFixtureTeardown(tester, fixture, () => body(inert, controller));
  }

  testWidgets('the speaker glyph is gone and the name leads the bar', (
    tester,
  ) async {
    await withRail(tester, _sharing, (_, _) async {
      expect(find.byIcon(AppIcons.voice), findsNothing);
      final row = tester.getRect(callRow);
      final summary = tester.getRect(find.byKey(railCallSummaryKey));
      expect(
        summary.left - row.left,
        lessThan(AppSpacing.s12),
        reason: 'the name takes the glyph column',
      );
    });
  });

  testWidgets('mute and deafen live in the call bar, not the profile row', (
    tester,
  ) async {
    await withRail(tester, _live, (_, controller) async {
      for (final label in ['Mute', 'Deafen']) {
        expect(find.bySemanticsLabel(label), findsOneWidget);
        final at = tester.getCenter(find.bySemanticsLabel(label));
        expect(tester.getRect(callRow).contains(at), isTrue, reason: label);
        expect(tester.getRect(bar).contains(at), isFalse, reason: label);
      }
      await tester.tap(find.bySemanticsLabel('Mute'));
      await tester.tap(find.bySemanticsLabel('Deafen'));
      expect(controller.calls, ['mute', 'deafen']);
      expect(find.bySemanticsLabel('Personal settings'), findsOneWidget);
    });
  });

  testWidgets(
    'a bar with no call row keeps mute and deafen in the profile row',
    (tester) async {
      final fixture = await fixtureContainer(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) => _Recorded(ref, _live, InertSession()),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: const Scaffold(
              body: Align(
                alignment: Alignment.bottomLeft,
                child: SizedBox(
                  width: 248,
                  child: RailUserFooter(activeChannelId: 'c-main'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 350));
      await withFixtureTeardown(tester, fixture, () async {
        expect(callRow, findsNothing);
        final at = tester.getCenter(find.bySemanticsLabel('Mute'));
        expect(tester.getRect(bar).contains(at), isTrue);
      });
    },
  );

  testWidgets('share starts a share through the call flow, with its ceiling', (
    tester,
  ) async {
    await withRail(tester, _live, session: InertSession(), (session, _) async {
      await tester.tap(find.bySemanticsLabel('Share a screen'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.screenShareCalls.map((c) => c.enabled), [true]);
    });
  });

  testWidgets('sharing: tap opens a menu that stops the share', (tester) async {
    await withRail(tester, _sharing, (session, _) async {
      await tester.tap(find.bySemanticsLabel('Screen share options'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Stop sharing'), findsOneWidget);
      await tester.tap(find.text('Stop sharing'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.screenShareCalls.map((c) => c.enabled), [false]);
    });
  });

  testWidgets('sharing: the menu switches the source through the same flow', (
    tester,
  ) async {
    await withRail(
      tester,
      _sharing,
      session: InertSession(
        needsSource: true,
        sourcePickerUseful: false,
        sources: Future.value([_share]),
      ),
      (session, _) async {
        await tester.tap(find.bySemanticsLabel('Screen share options'));
        await tester.pump(const Duration(milliseconds: 350));
        await tester.tap(find.text('Sharing'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));
        expect(session.screenShareCalls.map((c) => c.enabled), [false, true]);
        expect(session.screenShareCalls.last.sourceId, 's1');
      },
    );
  });

  for (final (room, shown) in [(56.0, false), (200.0, true)]) {
    testWidgets('the sharing status is whole or absent in $room px', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: room,
                child: RailCallSummary(
                  channelName: 'main',
                  connectedAt: DateTime.now().subtract(
                    const Duration(minutes: 34),
                  ),
                  screenSharing: true,
                  onOpen: () async {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.textContaining('sharing'), shown ? findsOne : findsNothing);
      if (shown) {
        final text = tester.widget<Text>(find.textContaining('sharing'));
        expect(text.overflow, isNot(TextOverflow.ellipsis));
      }
    });
  }

  testWidgets('the profile name shows at a 200 px rail with the call bar up', (
    tester,
  ) async {
    await withRail(tester, _live, width: 200, (_, _) async {
      expect(tester.takeException(), isNull, reason: 'no overflow');
      final name = find.byKey(railFooterNameKey);
      expect(name, findsOneWidget);
      final bar = tester.getRect(find.byKey(const Key('rail-footer-padding')));
      final rect = tester.getRect(name);
      final notes = tester.getRect(find.bySemanticsLabel('Notes'));
      expect(rect.left, greaterThanOrEqualTo(bar.left));
      expect(rect.right, lessThanOrEqualTo(notes.left), reason: 'whole name');
    });
  });

  for (final (width, touch) in [
    (ChannelRail.compactWidth, false),
    (ChannelRail.expandedWidth, false),
    (320.0, true),
  ]) {
    testWidgets('the bar fits a $width rail${touch ? ' at touch' : ''}', (
      tester,
    ) async {
      await withRail(tester, _sharing, width: width, touch: touch, (
        _,
        _,
      ) async {
        expect(tester.takeException(), isNull, reason: 'no overflow');
        final row = tester.getRect(callRow);
        final minHit = touch ? AppSizes.rowTouch : AppSizes.rowPointer;
        var previousRight = tester
            .getRect(find.byKey(railCallSummaryKey))
            .right;
        expect(
          tester.getRect(find.byKey(railCallSummaryKey)).width,
          greaterThan(48),
          reason: 'the name keeps room',
        );
        for (final label in [
          'Mute',
          'Deafen',
          'Screen share options',
          'Leave call',
        ]) {
          final rect = tester.getRect(find.bySemanticsLabel(label));
          expect(rect.width, greaterThanOrEqualTo(minHit), reason: label);
          expect(rect.height, greaterThanOrEqualTo(minHit), reason: label);
          expect(rect.left, greaterThanOrEqualTo(previousRight - 0.5));
          expect(rect.right, lessThanOrEqualTo(row.right + 0.5), reason: label);
          previousRight = rect.right;
        }
      });
    });
  }
}
