// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call mini-player on the real shell: when it shows, where it rests after
/// a real drag, and what it never covers.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_app/src/features/channels/widgets/compact_channel_app_bar.dart';
import 'package:slimm_app/src/features/composer/widgets/composer.dart';
import 'package:slimm_app/src/features/channels/widgets/rail_call_summary.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'call_mini_player_harness.dart';

Rect _rectOf(WidgetTester tester, Finder f) => tester.getRect(f);

void main() {
  setUpAll(loadRealFonts);

  final player = find.byKey(miniPlayerKey);

  group('when it shows', () {
    testWidgets('a remote share, on another channel', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      expect(player, findsOneWidget);
      await ctx.done();
    });

    testWidgets('not on the channel the call is in', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-main',
        voice: miniCall([remoteShare]),
      );
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('not over the switch button of another voice channel', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-main',
        voice: const VoiceState(
          channelId: 'c-design',
          state: VoiceSessionState.connected,
          participants: [remoteShare],
        ),
      );
      final switchButton = find.text('Switch to this call');
      expect(switchButton, findsOneWidget);
      expect(
        player.evaluate().isEmpty ||
            !_rectOf(tester, player).overlaps(_rectOf(tester, switchButton)),
        isTrue,
        reason: 'the card must not sit on the page\'s own primary action',
      );
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('not when there is only audio to carry', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteQuiet]),
      );
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('not for your own share', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([localShare]),
      );
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('not without a connected call', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: const VoiceState(participants: [remoteShare]),
      );
      expect(player, findsNothing);
      await ctx.done();
    });
  });

  group('placement', () {
    testWidgets('starts bottom-right and clear of the composer, phone', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final p = _rectOf(tester, player);
      final composer = _rectOf(tester, find.byType(Composer));
      expect(p.right, closeTo(phoneSize.width - 12, 0.5));
      expect(p.bottom, lessThanOrEqualTo(composer.top));
      await ctx.done();
    });

    testWidgets('sits above the compact call strip, never over it', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final strip = _rectOf(tester, find.byType(VoiceStripIndicator));
      expect(_rectOf(tester, player).bottom, lessThanOrEqualTo(strip.top));
      await ctx.done();
    });

    testWidgets('is hidden while the keyboard is up', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      await settleMini(tester);
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('every corner clears the composer, wide', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: desktopSize,
      );
      final composer = _rectOf(tester, find.byType(Composer));
      for (final corner in MiniPlayerCorner.values) {
        ctx.container.read(miniPlayerCornerProvider.notifier).state = corner;
        await settleMini(tester);
        final p = _rectOf(tester, player);
        expect(
          p.overlaps(composer),
          isFalse,
          reason: '$corner $p overlaps the composer $composer',
        );
      }
      await ctx.done();
    });

    testWidgets('every corner clears the composer, phone', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final composer = _rectOf(tester, find.byType(Composer));
      for (final corner in MiniPlayerCorner.values) {
        ctx.container.read(miniPlayerCornerProvider.notifier).state = corner;
        await settleMini(tester);
        expect(_rectOf(tester, player).overlaps(composer), isFalse);
      }
      await ctx.done();
    });
  });

  group('dragging', () {
    testWidgets('a real drag to the top-left snaps there and is remembered', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final start = _rectOf(tester, player);
      await tester.timedDragFrom(
        start.center - const Offset(0, 20),
        Offset(-(start.left) - 40, -(start.top) - 200),
        const Duration(milliseconds: 300),
      );
      await settleMini(tester);

      final end = _rectOf(tester, player);
      expect(end.left, closeTo(12, 0.5));
      final header = _rectOf(tester, find.byType(CompactChannelAppBar));
      expect(end.top, greaterThanOrEqualTo(header.bottom + 12 - 0.5));
      expect(end.top, lessThan(header.bottom + 60));
      expect(
        ctx.container.read(miniPlayerCornerProvider),
        MiniPlayerCorner.topLeft,
      );
      await ctx.done();
    });

    testWidgets('a short drag settles back to the corner it started in', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final start = _rectOf(tester, player);
      await tester.dragFrom(
        start.center - const Offset(0, 20),
        const Offset(-30, -30),
      );
      await settleMini(tester);
      expect(_rectOf(tester, player), start);
      await ctx.done();
    });

    testWidgets('the corner survives leaving and re-entering the pane', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: desktopSize,
      );
      ctx.container.read(miniPlayerCornerProvider.notifier).state =
          MiniPlayerCorner.topRight;
      ctx.router.go('/channels/c-main');
      await settleMini(tester);
      expect(player, findsNothing);
      ctx.router.go('/channels/c-general');
      await settleMini(tester);
      final p = _rectOf(tester, player);
      expect(p.right, greaterThan(desktopSize.width - 400));
      expect(p.top, lessThan(desktopSize.height / 4));
      await ctx.done();
    });
  });

  group('controls', () {
    testWidgets('tapping the video returns to the call', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      await tester.tapAt(
        _rectOf(tester, player).topCenter + const Offset(0, 30),
      );
      await settleMini(tester);
      expect(
        ctx.router.routeInformationProvider.value.uri.path,
        '/channels/c-main',
      );
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('mute and leave act on the call, wide', (tester) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: desktopSize,
      );
      await tester.tap(inPlayer('Mute'));
      await tester.pump();
      expect(
        ctx.container.read(voiceControllerProvider).microphoneEnabled,
        isFalse,
      );
      await tester.tap(inPlayer('Leave call'));
      await settleMini(tester);
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('on a phone the card leaves mute and leave to the strip', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
      );
      final strip = find.byType(VoiceStripIndicator);
      for (final action in ['Mute', 'Leave call']) {
        expect(inPlayer(action), findsNothing, reason: '$action shows twice');
        expect(
          find.descendant(of: strip, matching: find.byTooltip(action)),
          findsOneWidget,
          reason: 'the strip keeps $action',
        );
      }
      await tester.tap(inPlayer('Hide the mini-player'));
      await settleMini(tester);
      expect(player, findsNothing);
      await ctx.done();
    });

    testWidgets('hide keeps the call, and the next navigation brings it back', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: desktopSize,
      );
      await tester.tap(inPlayer('Hide the mini-player'));
      await settleMini(tester);
      expect(player, findsNothing);
      expect(
        ctx.container.read(voiceControllerProvider).state,
        VoiceSessionState.connected,
      );
      ctx.router.go('/channels/c-design');
      await settleMini(tester);
      expect(player, findsOneWidget);
      await ctx.done();
    });

    testWidgets('wide layout folds the call into the rail, not a strip', (
      tester,
    ) async {
      final ctx = await pumpMini(
        tester,
        location: '/channels/c-general',
        voice: miniCall([remoteShare]),
        size: desktopSize,
      );
      expect(find.byType(RailCallSummary), findsOneWidget);
      expect(player, findsOneWidget);
      await ctx.done();
    });
  });

  group('snapshots', () {
    for (final (name, size) in [
      ('phone', phoneSize),
      ('desktop', desktopSize),
    ]) {
      for (final mode in [Brightness.light, Brightness.dark]) {
        testWidgets('$name ${mode.name}', (tester) async {
          final ctx = await pumpMini(
            tester,
            location: '/channels/c-general',
            voice: miniCall([remoteShare]),
            size: size,
            brightness: mode,
          );
          expect(player, findsOneWidget);
          await writeSnapshot(tester, 'call-mini-player-$name-${mode.name}');
          await ctx.done();
        });
      }
    }
  });
}
