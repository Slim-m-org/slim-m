// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The desktop pop-out: what offers it, what opens and closes the window, and
/// that the window's controls act on the same call the main window holds.
library;

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/desktop/popout/popout_windowing.dart';
import 'package:slimm_app/src/desktop/desktop_window_port.dart' show ResizeEdge;
import 'package:slimm_app/src/features/voice/providers/call_mini_player.dart';
import 'package:slimm_app/src/providers/app_lock_controller.dart';
import 'package:slimm_app/src/features/voice/providers/popout_window.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_mini_player.dart';
import 'package:slimm_app/src/features/voice/widgets/popout_window_view.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';
import 'popout_window_support.dart';

double _headerOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.text("Ada's screen"),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

Future<void> _hover(WidgetTester tester) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(const Offset(300, 200));
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('no pop-out control where windowing is unavailable', (
    tester,
  ) async {
    final rig = await pumpPopOut(tester, supported: false);
    expect(find.byKey(miniPlayerKey), findsOneWidget);
    expect(popOutButton, findsNothing);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('pop out opens a window; closing it keeps the call', (
    tester,
  ) async {
    final rig = await pumpPopOut(tester, supported: true);
    await tester.tap(popOutButton);
    await tester.pump();
    expect(rig.windows, hasLength(1));
    expect(rig.container.read(popOutFeedsProvider), [screenFeed(adaSharing)]);

    rig.windows.single.onCloseRequested();
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    expect(rig.container.read(popOutFeedsProvider), isEmpty);
    expect(rig.session.leaveCalls, 0);
    expect(rig.voice.state.state, VoiceSessionState.connected);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window is requested without OS decorations', (tester) async {
    final rig = await pumpPopOut(tester, supported: true);
    await tester.tap(popOutButton);
    await tester.pump();
    expect(rig.windows.single.decorated, isFalse);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window stays above the others under its own title', (
    tester,
  ) async {
    final rig = await pumpPopOut(tester, supported: true);
    await tester.tap(popOutButton);
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(rig.windows.single.title, popOutWindowTitle);
    expect(rig.windows.single.keptAbove, greaterThan(0));
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window closes when the share stops', (tester) async {
    final rig = await pumpPopOut(tester, supported: true);
    await tester.tap(popOutButton);
    await tester.pump();
    rig.voice.replace(callOf([adaStopped]));
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    expect(rig.container.read(popOutFeedsProvider), isEmpty);
    await teardownFixture(tester, rig.container, rig.db);
  });

  testWidgets('the window closes when the call ends', (tester) async {
    final rig = await pumpPopOut(tester, supported: true);
    await tester.tap(popOutButton);
    await tester.pump();
    rig.voice.replace(const VoiceState());
    await tester.pump();
    expect(rig.windows.single.destroyed, isTrue);
    await teardownFixture(tester, rig.container, rig.db);
  });

  group('several pop-outs', () {
    Future<PopOutRig> twoOut(WidgetTester tester) async {
      final rig = await pumpPopOut(
        tester,
        supported: true,
        who: [adaSharing, boSharing],
      );
      rig.container
          .read(popOutFeedsProvider.notifier)
          .open(screenFeed(adaSharing));
      await tester.pump();
      rig.container
          .read(popOutFeedsProvider.notifier)
          .open(screenFeed(boSharing));
      await tester.pump();
      return rig;
    }

    testWidgets('two feeds give two windows', (tester) async {
      final rig = await twoOut(tester);
      expect(rig.windows, hasLength(2));
      expect(rig.windows.where((w) => w.destroyed), isEmpty);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('closing one keeps the other', (tester) async {
      final rig = await twoOut(tester);
      rig.windows.first.onCloseRequested();
      await tester.pump();
      expect(rig.windows.map((w) => w.destroyed), [true, false]);
      expect(rig.container.read(popOutFeedsProvider), [screenFeed(boSharing)]);
      expect(rig.session.leaveCalls, 0);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('one stream ending closes only its window', (tester) async {
      final rig = await twoOut(tester);
      rig.voice.replace(callOf([adaStopped, boSharing]));
      await tester.pump();
      expect(rig.windows.map((w) => w.destroyed), [true, false]);
      expect(rig.container.read(popOutFeedsProvider), [screenFeed(boSharing)]);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('leaving the call closes every window', (tester) async {
      final rig = await twoOut(tester);
      rig.voice.replace(const VoiceState());
      await tester.pump();
      expect(rig.windows.map((w) => w.destroyed), [true, true]);
      expect(rig.container.read(popOutFeedsProvider), isEmpty);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('the app lock closes every window', (tester) async {
      final rig = await twoOut(tester);
      // ignore: invalid_use_of_protected_member
      rig.container.read(appLockControllerProvider.notifier).state = true;
      await tester.pump();
      expect(rig.windows.map((w) => w.destroyed), [true, true]);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('popping the same feed twice opens one window', (tester) async {
      final rig = await twoOut(tester);
      rig.container
          .read(popOutFeedsProvider.notifier)
          .open(screenFeed(adaSharing));
      await tester.pump();
      expect(rig.windows, hasLength(2));
      expect(rig.container.read(popOutFeedsProvider), hasLength(2));
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('a camera and a screen of one person are two windows', (
      tester,
    ) async {
      final rig = await pumpPopOut(
        tester,
        supported: true,
        who: [adaSharing.copyWith(isCameraOn: true)],
      );
      final feeds = rig.container.read(popOutFeedsProvider.notifier);
      feeds.open(screenFeed(adaSharing));
      feeds.open((identity: 'u-ada', name: 'Ada', kind: FeedKind.camera));
      await tester.pump();
      expect(rig.windows, hasLength(2));
      await teardownFixture(tester, rig.container, rig.db);
    });
  });

  group('window content', () {
    var moves = 0;
    var closes = 0;
    final resizes = <ResizeEdge>[];
    final frame = PopOutFrame(
      onMoveStart: () => moves++,
      onResizeStart: resizes.add,
      onClose: () => closes++,
    );

    Future<PopOutRig> content(
      WidgetTester tester,
      double width, {
      PopOutFrame? frame,
    }) async {
      final rig = PopOutRig();
      final fixture = await fixtureContainer(
        extraOverrides: [
          voiceControllerProvider.overrideWith(
            (ref) =>
                FixedVoiceController(ref, callOf([adaSharing]), rig.session),
          ),
        ],
      );
      rig.container = fixture.container;
      rig.db = fixture.db;
      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: fixture.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: PopOutWindowView(
              feed: (
                identity: 'u-ada',
                name: 'Ada',
                kind: FeedKind.screenShare,
              ),
              frame: frame,
            ),
          ),
        ),
      );
      await tester.pump();
      return rig;
    }

    testWidgets('borderless frame: drag, resize edges and close', (
      tester,
    ) async {
      final rig = await content(tester, 640, frame: frame);
      await tester.startGesture(
        tester.getCenter(find.byKey(popOutDragRegionKey)),
      );
      expect(moves, 1);
      await _hover(tester);
      expect(find.byTooltip('Close pop-out'), findsOneWidget);
      await tester.tap(find.byTooltip('Close pop-out'));
      expect(closes, 1);
      final corner = tester.getBottomRight(find.byKey(popOutWindowKey));
      await tester.dragFrom(
        corner - const Offset(2, 2),
        const Offset(-20, -20),
      );
      expect(resizes, [ResizeEdge.bottomRight]);
      expect(rig.session.leaveCalls, 0);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('the borderless window has no permanent header', (
      tester,
    ) async {
      final rig = await content(tester, 640, frame: frame);
      expect(_headerOpacity(tester), 0);
      expect(find.text("Ada's screen"), findsOneWidget);
      await _hover(tester);
      expect(_headerOpacity(tester), 1);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('a decorated window draws no frame of its own', (tester) async {
      final rig = await content(tester, 640);
      expect(find.byKey(popOutDragRegionKey), findsNothing);
      expect(find.byTooltip('Close pop-out'), findsNothing);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('mute and leave act on the shared call', (tester) async {
      final rig = await content(tester, 640);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(rig.voice.state.microphoneEnabled, isFalse);
      await tester.tap(find.byTooltip('Leave call'));
      await tester.pump();
      expect(rig.session.leaveCalls, 1);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('the mute button follows the call state', (tester) async {
      final rig = await content(tester, 640);
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump();
      expect(find.byTooltip('Unmute'), findsOneWidget);
      expect(find.byTooltip('Mute'), findsNothing);
      await tester.tap(find.byTooltip('Unmute'));
      await tester.pump();
      expect(find.byTooltip('Mute'), findsOneWidget);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('a new feed replaces the one on show', (tester) async {
      final rig = await content(tester, 640, frame: frame);
      expect(find.text("Ada's screen"), findsOneWidget);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: rig.container,
          child: MaterialApp(
            theme: buildTheme(Brightness.dark, AppTokens.dark),
            home: PopOutWindowView(
              feed: (identity: 'u-bo', name: 'Bo', kind: FeedKind.screenShare),
              frame: frame,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text("Bo's screen"), findsOneWidget);
      expect(find.text("Ada's screen"), findsNothing);
      await teardownFixture(tester, rig.container, rig.db);
    });

    testWidgets('control density follows the window width', (tester) async {
      final wide = await content(tester, 900);
      final pointer = tester.getSize(find.byTooltip('Mute')).height;
      await teardownFixture(tester, wide.container, wide.db);
      final narrow = await content(tester, 320);
      final touch = tester.getSize(find.byTooltip('Mute')).height;
      expect(pointer, AppSizes.rowPointer);
      expect(touch, AppSizes.rowTouch);
      await teardownFixture(tester, narrow.container, narrow.db);
    });
  });
}
