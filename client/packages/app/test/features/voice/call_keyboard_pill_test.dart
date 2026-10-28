// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// With the keyboard up on a phone, the call strip is a slim pill above the composer.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/main.dart' show appChromeBuilder;
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/call_keyboard_pill.dart';
import 'package:slimm_app/src/features/voice/widgets/voice_strip_indicator.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../ui_snapshot_support.dart';
import 'voice_controller_harness.dart';

class _CountingVoiceController extends VoiceController {
  _CountingVoiceController(super.ref, VoiceState fixed)
    : super(session: FakeSession()) {
    state = fixed;
  }

  final calls = <String>[];

  @override
  Future<void> toggleMicrophone() async => calls.add('mute');

  @override
  Future<void> leave() async => calls.add('leave');
}

Future<(_CountingVoiceController, Future<void> Function())> _pump(
  WidgetTester tester, {
  required double keyboard,
}) async {
  late _CountingVoiceController controller;
  final fixture = await fixtureContainer(
    extraOverrides: [
      voiceControllerProvider.overrideWith((ref) {
        controller = _CountingVoiceController(
          ref,
          VoiceState(
            channelId: 'c-main',
            state: VoiceSessionState.connected,
            connectedAt: DateTime.now().subtract(const Duration(seconds: 36)),
          ),
        );
        return controller;
      }),
    ],
  );
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1.0;
  tester.view.viewInsets = FakeViewPadding(bottom: keyboard);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: fixture.container,
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.dark, AppTokens.dark),
        routerConfig: fixtureRouter('/channels/c-general'),
        builder: appChromeBuilder,
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 350));
  return (
    controller,
    () => teardownFixture(tester, fixture.container, fixture.db),
  );
}

void main() {
  setUpAll(loadRealFonts);

  testWidgets('keyboard up: a slim pill replaces the full strip', (
    tester,
  ) async {
    final (controller, done) = await _pump(tester, keyboard: 300);
    expect(find.byType(CallKeyboardPill), findsOneWidget);
    expect(find.byType(VoiceStripIndicator), findsNothing);
    expect(
      tester.getSize(find.byType(CallKeyboardPill)).height,
      lessThanOrEqualTo(AppSizes.rowTouch + 2 * AppSpacing.s4 + 2),
    );
    expect(find.textContaining(RegExp(r'^\d\d:\d\d$')), findsOneWidget);
    await tester.tap(find.byTooltip('Mute'));
    await tester.tap(find.byTooltip('Leave call'));
    expect(controller.calls, ['mute', 'leave']);
    await done();
  });

  testWidgets('keyboard down: the full strip, no pill', (tester) async {
    final (_, done) = await _pump(tester, keyboard: 0);
    expect(find.byType(CallKeyboardPill), findsNothing);
    expect(find.byType(VoiceStripIndicator), findsOneWidget);
    await done();
  });

  test('the pill needs a phone width, the keyboard, and a call elsewhere', () {
    bool shows({
      double width = 390,
      bool keyboardUp = true,
      VoiceSessionState state = VoiceSessionState.connected,
      String? call = 'c-main',
    }) => showsCallKeyboardPill(
      width: width,
      keyboardUp: keyboardUp,
      state: state,
      callChannelId: call,
      channelId: 'c-general',
    );
    expect(shows(), isTrue);
    expect(shows(width: kCompactWidth), isFalse);
    expect(shows(keyboardUp: false), isFalse);
    expect(shows(state: VoiceSessionState.idle), isFalse);
    expect(shows(call: 'c-general'), isFalse);
  });
}
