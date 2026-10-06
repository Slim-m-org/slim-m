// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The in-call shortcuts (mute, camera, share, leave) are listed in settings
/// as global, so they must keep working wherever focus sits in the shell: the
/// chat composer beside a call, a tile, the canvas. Driven through the real
/// `HomeShell` and `CallControls`, with a text field standing in for the
/// composer, the way a person in a call actually presses the keys.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/screens/home_shell.dart';
import 'package:slimm_app/src/screens/voice_call_controls.dart';
import 'package:slimm_data/data.dart' show SlimmDatabase;
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'home_shell_harness.dart';
import 'voice_call_controls_harness.dart';

GoRouter _router(ProviderContainer container) => GoRouter(
  initialLocation: '/call',
  routes: [
    ShellRoute(
      builder: (context, state, child) => HomeShell(child: child),
      routes: [
        GoRoute(
          path: '/call',
          builder: (context, state) => Scaffold(
            body: Column(
              children: [
                const TextField(key: Key('composer')),
                TextButton(
                  onPressed: () => context.go('/elsewhere'),
                  child: const Text('leave the call screen'),
                ),
                CallControls(
                  controller: container.read(voiceControllerProvider.notifier),
                  voice: const VoiceFlags(state: VoiceSessionState.connected),
                ),
              ],
            ),
          ),
        ),
        GoRoute(
          path: '/elsewhere',
          builder: (context, state) =>
              const Scaffold(body: TextField(key: Key('composer'))),
        ),
      ],
    ),
  ],
);

Future<({ProviderContainer container, InertSession session, SlimmDatabase db})>
_pump(WidgetTester tester) async {
  final session = InertSession();
  final s = setup(
    httpClient: quietClient(),
    signedIn: true,
    extraOverrides: [
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: session),
      ),
    ],
  );
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: s.container,
      child: MaterialApp.router(
        theme: buildTheme(Brightness.light, AppTokens.light),
        routerConfig: _router(s.container),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (container: s.container, session: session, db: s.db);
}

Future<void> _ctrlShift(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
}

void main() {
  testWidgets('Ctrl+Shift+M mutes while the composer has focus', (
    tester,
  ) async {
    final p = await _pump(tester);
    final controller = p.container.read(voiceControllerProvider.notifier);
    expect(controller.state.microphoneEnabled, isTrue);

    await tester.tap(find.byKey(const Key('composer')));
    await tester.pump();
    await _ctrlShift(tester, LogicalKeyboardKey.keyM);

    expect(
      controller.state.microphoneEnabled,
      isFalse,
      reason: 'the settings list this as an in-call shortcut',
    );
    await _ctrlShift(tester, LogicalKeyboardKey.keyM);
    expect(controller.state.microphoneEnabled, isTrue);
    await teardown(tester, p.container, p.db);
  });

  testWidgets('Ctrl+Shift+V, S and H reach the session from the composer', (
    tester,
  ) async {
    final p = await _pump(tester);
    await tester.tap(find.byKey(const Key('composer')));
    await tester.pump();

    await _ctrlShift(tester, LogicalKeyboardKey.keyV);
    expect(p.session.setCameraCalls, [true]);

    await _ctrlShift(tester, LogicalKeyboardKey.keyS);
    await tester.pump();
    expect(p.session.screenShareCalls, isNotEmpty);
    expect(p.session.screenShareCalls.first.enabled, isTrue);

    await _ctrlShift(tester, LogicalKeyboardKey.keyH);
    expect(p.session.leaveCalls, 1);
    await teardown(tester, p.container, p.db);
  });

  testWidgets('with no call row on screen the shortcuts do nothing', (
    tester,
  ) async {
    final p = await _pump(tester);
    final controller = p.container.read(voiceControllerProvider.notifier);

    await tester.tap(find.text('leave the call screen'));
    await tester.pumpAndSettle();
    expect(find.byType(CallControls), findsNothing);
    await tester.tap(find.byKey(const Key('composer')));
    await tester.pump();
    await _ctrlShift(tester, LogicalKeyboardKey.keyM);

    expect(controller.state.microphoneEnabled, isTrue);
    expect(p.session.leaveCalls, 0);
    await teardown(tester, p.container, p.db);
  });
}
