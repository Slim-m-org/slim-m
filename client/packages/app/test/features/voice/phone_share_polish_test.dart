// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Phone watching polish: a phone turned to landscape in full screen keeps finger-sized controls and clear of the notch, a pinch also drags the picture, and the mini-player's buttons carry their own dark backing.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/providers/share_zoom_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/fullscreen_video_overlay.dart';
import 'package:slimm_app/src/features/voice/widgets/share_zoom_view.dart';
import 'package:slimm_app/src/providers/phone_landscape.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_voice.dart';
import '../../ui_snapshot_support.dart' show loadRealFonts;
import 'call_mini_player_harness.dart';
import 'voice_controller_harness.dart';

const _ada = VoiceParticipant(
  identity: 'u-ada',
  name: 'Ada',
  isSpeaking: false,
  isMuted: false,
  isLocal: false,
  isScreenSharing: true,
);

const _landscape = Size(844, 390);

Future<void> _openShareLandscape(
  WidgetTester tester, {
  required bool lockedPhone,
}) async {
  tester.view.physicalSize = _landscape;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        portraitLockedPhoneProvider.overrideWith((ref) => lockedPhone),
        voiceControllerProvider.overrideWith(
          (ref) => FakeVoiceController(
            ref,
            session: FakeSession(),
            initial: const VoiceState(
              channelId: 'c-main',
              state: VoiceSessionState.connected,
              participants: [_ada],
            ),
          ),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        // What appChromeBuilder does above the navigator.
        builder: (context, child) => Consumer(
          builder: (context, ref, _) => MediaQuery(
            data: keepPortraitShell(
              MediaQueryData.fromView(View.of(context)),
              lockedPhone: ref.watch(portraitLockedPhoneProvider),
            ),
            child: child!,
          ),
        ),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showFullscreenVideo(
              context,
              identity: 'u-ada',
              label: "Ada's screen",
              kind: FullscreenVideoKind.screenShare,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  await tester.sendKeyEvent(LogicalKeyboardKey.equal);
  await tester.pump();
}

Future<void> _pinch(
  WidgetTester tester, {
  required Offset a,
  required Offset b,
  required Offset drift,
}) async {
  final first = await tester.startGesture(a, kind: PointerDeviceKind.touch);
  final second = await tester.startGesture(b, kind: PointerDeviceKind.touch);
  for (var i = 1; i <= 4; i++) {
    await first.moveTo(a + drift * (i / 4));
    await second.moveTo(b + drift * (i / 4));
  }
  await first.up();
  await second.up();
}

void main() {
  setUpAll(loadRealFonts);

  group('a phone turned to landscape in full screen', () {
    testWidgets('keeps finger-sized controls', (tester) async {
      await _openShareLandscape(tester, lockedPhone: true);

      final reset = tester.getSize(
        find.byKey(const ValueKey('share-zoom-reset')),
      );
      expect(reset.shortestSide, greaterThanOrEqualTo(AppSizes.rowTouch));
    });

    testWidgets('a desktop window the same size stays pointer-sized', (
      tester,
    ) async {
      await _openShareLandscape(tester, lockedPhone: false);

      final reset = tester.getSize(
        find.byKey(const ValueKey('share-zoom-reset')),
      );
      expect(reset.shortestSide, lessThan(AppSizes.rowTouch));
    });

    testWidgets('keeps the zoom indicator out from under the notch', (
      tester,
    ) async {
      tester.view.padding = const FakeViewPadding(left: 47, right: 47);
      addTearDown(tester.view.resetPadding);
      await _openShareLandscape(tester, lockedPhone: true);

      final pill = tester.getRect(
        find.byKey(const ValueKey('share-zoom-level')),
      );
      expect(pill.right, lessThanOrEqualTo(_landscape.width - 47));
    });
  });

  group('a pinch', () {
    testWidgets('drags the picture when both fingers slide together', (
      tester,
    ) async {
      final zoom = ShareZoomController()..zoomAt(2, const Offset(0.5, 0.5));
      addTearDown(zoom.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: SizedBox(
            width: 400,
            height: 300,
            child: ShareZoomView(zoom: zoom, child: const SizedBox.expand()),
          ),
        ),
      );
      final before = zoom.origin;

      await _pinch(
        tester,
        a: const Offset(150, 150),
        b: const Offset(250, 150),
        drift: const Offset(40, 0),
      );

      expect(zoom.scale, 2);
      expect(zoom.origin.dx, greaterThan(before.dx));
    });
  });

  testWidgets('the mini-player buttons stay legible in a light theme', (
    tester,
  ) async {
    final ctx = await pumpMini(
      tester,
      location: '/channels/c-general',
      voice: miniCall(const [remoteShare]),
      brightness: Brightness.light,
    );
    await settleMini(tester);

    final hide = tester.element(inPlayer('Hide the mini-player'));
    expect(Theme.of(hide).brightness, Brightness.dark);
    await ctx.done();
  });
}
