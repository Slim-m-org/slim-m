// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A settings screen is a screen on a phone and a modal on a desktop.
///
/// These screens took the whole window at every size, which on a monitor meant
/// swallowing 1280 points to show eight rows and hiding the app behind them.
/// A phone still gets the whole window, because that is the point there.
///
/// A phone screen taking the whole window also means an active call has no
/// window margin left to stay visible through, unlike the desktop's floating
/// panel; [_ActiveCallReminder] is the compact replacement, covered below.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/routing/modal_page.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'voice_controller_harness.dart';

const Size _phone = Size(390, 844);
const Size _desktop = Size(1280, 900);

/// The screen being presented, marked so it can be found whichever way it is.
const Key _screenKey = Key('screen-under-test');

const _noCall = VoiceState();
final _inCall = VoiceState(
  state: VoiceSessionState.connected,
  channelId: 'c1',
  connectedAt: DateTime(2024, 1, 1),
);

Future<void> _open(
  WidgetTester tester,
  Size window, {
  VoiceState voiceState = _noCall,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, voiceState),
        ),
      ],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        navigatorKey: navigator,
        home: Scaffold(
          body: Center(
            child: Builder(
              builder: (context) => TextButton(
                onPressed: () => navigator.currentState!.push(
                  modalPage(
                    context,
                    const ColoredBox(
                      key: _screenKey,
                      color: Color(0xFF202020),
                      child: SizedBox.expand(),
                    ),
                  ).createRoute(context),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The page [modalPage] hands back, without pushing it: the transition is a
/// property of the page, and reading it there says what a viewer would get
/// rather than what one run of the animation happened to do.
Future<Page<void>> _pageFor(
  WidgetTester tester,
  Size window, {
  required bool reduceMotion,
}) async {
  tester.view.physicalSize = window;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  late Page<void> page;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        voiceControllerProvider.overrideWith(
          (ref) => FixedVoiceController(ref, _noCall),
        ),
      ],
      child: MediaQuery(
        // From the view: a bare MediaQueryData reports Size.zero, which reads
        // as a phone and would answer the desktop half of this with the
        // other one.
        data: MediaQueryData.fromView(
          tester.view,
        ).copyWith(disableAnimations: reduceMotion),
        child: MaterialApp(
          theme: buildTheme(Brightness.dark, AppTokens.dark),
          home: Builder(
            builder: (context) {
              page = modalPage(context, const SizedBox.shrink());
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    ),
  );
  return page;
}

void main() {
  testWidgets('a phone gives the screen the whole window', (tester) async {
    await _open(tester, _phone);

    final box = tester.getRect(find.byKey(_screenKey));
    expect(box.width, _phone.width);
    expect(box.height, _phone.height);
  });

  testWidgets('a desktop window floats it instead', (tester) async {
    await _open(tester, _desktop);

    final box = tester.getRect(find.byKey(_screenKey));
    expect(box.width, lessThanOrEqualTo(kModalMaxWidth));
    expect(box.height, lessThanOrEqualTo(kModalMaxHeight));
    // The complaint that started this: a monitor's worth of window for a list.
    expect(box.width, lessThan(_desktop.width));
    expect(box.height, lessThan(_desktop.height));
  });

  testWidgets('the floating panel is centred', (tester) async {
    await _open(tester, _desktop);

    final box = tester.getRect(find.byKey(_screenKey));
    expect(box.center.dx, closeTo(_desktop.width / 2, 1));
    expect(box.center.dy, closeTo(_desktop.height / 2, 1));
  });

  testWidgets('the app behind it is still there to click beside', (
    tester,
  ) async {
    await _open(tester, _desktop);

    // Not opaque: whatever was on screen stays mounted underneath, which is
    // what makes this read as a modal rather than as a new screen.
    final route = ModalRoute.of(tester.element(find.byKey(_screenKey)))!;
    expect(route.opaque, isFalse);
    expect(route.barrierDismissible, isTrue);
  });

  group('the compact call strip', () {
    testWidgets('is absent with no call to reach', (tester) async {
      await _open(tester, _phone, voiceState: _noCall);

      expect(find.byType(VoiceStripIndicator).hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('Leave call'), findsNothing);
    });

    testWidgets('is the same strip the shell shows, with mute and leave', (
      tester,
    ) async {
      // The gap: a full-window phone screen left a call nowhere to be muted or left from.
      await _open(tester, _phone, voiceState: _inCall);

      expect(find.byType(VoiceStripIndicator), findsOneWidget);
      final strip = tester.getRect(find.byType(VoiceStripIndicator));
      expect(
        strip.bottom,
        _phone.height,
        reason: 'at the bottom, like every other phone screen',
      );

      await tester.tap(find.bySemanticsLabel('Mute'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Unmute'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('Leave call'));
      await tester.pumpAndSettle();
      expect(find.byType(VoiceStripIndicator).hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('Leave call'), findsNothing);
    });

    testWidgets('does not show on the floating desktop panel', (tester) async {
      // Compact-only: the desktop panel already leaves the app visible-and-dimmed.
      await _open(tester, _desktop, voiceState: _inCall);

      expect(find.byType(VoiceStripIndicator).hitTestable(), findsNothing);
      expect(find.bySemanticsLabel('Leave call'), findsNothing);
    });
  });

  group('reduce motion', () {
    testWidgets('takes the fade off the floating panel', (tester) async {
      final moving = await _pageFor(tester, _desktop, reduceMotion: false);
      expect(
        (moving as CustomTransitionPage<void>).transitionDuration,
        greaterThan(Duration.zero),
      );

      final still = await _pageFor(tester, _desktop, reduceMotion: true);
      expect(
        (still as CustomTransitionPage<void>).transitionDuration,
        Duration.zero,
      );
      expect(still.reverseTransitionDuration, Duration.zero);
    });

    testWidgets('takes the slide off the phone screen', (tester) async {
      final moving = await _pageFor(tester, _phone, reduceMotion: false);
      expect(
        (moving as CustomTransitionPage<void>).transitionDuration,
        greaterThan(Duration.zero),
      );
      final still = await _pageFor(tester, _phone, reduceMotion: true);
      expect(
        (still as CustomTransitionPage<void>).transitionDuration,
        Duration.zero,
      );
    });
  });
}
