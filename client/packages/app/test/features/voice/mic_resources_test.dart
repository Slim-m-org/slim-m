// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Microphone meters cost something only while one is on screen in a focused
/// app: the preview capture closes on blur or a covered route, the in-call
/// level polling follows the same signal, and a speaking ring stops pulsing.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/members/widgets/user_avatar.dart';
import 'package:slimm_app/src/features/voice/providers/level_display.dart';
import 'package:slimm_app/src/features/voice/providers/mic_preview.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/widgets/level_display_hold.dart';
import 'package:slimm_app/src/features/voice/widgets/mic_preview_hold.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/fake_mic_preview.dart';
import 'voice_settings_screen_harness.dart';

/// Tracks whether a capture is open, and whether two ever were at once.
class _Source extends FakeMicSource {
  bool isOpen = false;
  int mostOpen = 0;
  int _open = 0;

  @override
  Future<void> open(String? deviceId) async {
    await super.open(deviceId);
    isOpen = true;
    mostOpen = ++_open > mostOpen ? _open : mostOpen;
  }

  @override
  Future<void> close() async {
    await super.close();
    if (isOpen) _open--;
    isOpen = false;
  }
}

/// Reports a call as up without a server to join.
class _CallController extends VoiceController {
  _CallController(super.ref, {required super.session});

  void connect() => state = const VoiceState(
    state: VoiceSessionState.connected,
    channelId: 'c1',
  );

  void hangUp() => state = const VoiceState();
}

class _Rig {
  _Rig() : source = _Source(), session = FakeSession();

  final _Source source;
  final FakeSession session;
  final shown = ValueNotifier(true);
  final covered = ValueNotifier(false);

  late final container = ProviderContainer(
    overrides: [
      voiceControllerProvider.overrideWith(
        (ref) => _CallController(ref, session: session),
      ),
      fakeMicPreview(source),
    ],
  );

  Widget get app => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: buildTheme(Brightness.light, AppTokens.light),
      home: Scaffold(
        body: ListenableBuilder(
          listenable: Listenable.merge([shown, covered]),
          builder: (_, _) => shown.value
              ? TickerMode(
                  enabled: !covered.value,
                  child: const MicPreviewHold(child: SizedBox()),
                )
              : const SizedBox(),
        ),
      ),
    ),
  );

  bool get captureOpen => source.isOpen;
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _end(WidgetTester tester, _Rig rig) async {
  await tester.pumpWidget(const SizedBox());
  await _settle(tester);
  rig.container.dispose();
}

void _lifecycle(WidgetTester tester, AppLifecycleState state) =>
    tester.binding.handleAppLifecycleStateChanged(state);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('blur closes the capture and focus reopens it', (tester) async {
    final rig = _Rig();
    await tester.pumpWidget(rig.app);
    await _settle(tester);
    expect(rig.captureOpen, isTrue);

    _lifecycle(tester, AppLifecycleState.inactive);
    await _settle(tester);
    expect(rig.captureOpen, isFalse, reason: 'the OS mic indicator is off');
    expect(
      rig.container.read(micPreviewProvider).status,
      MicPreviewStatus.idle,
    );

    _lifecycle(tester, AppLifecycleState.resumed);
    await _settle(tester);
    expect(rig.captureOpen, isTrue);
    await _end(tester, rig);
  });

  testWidgets('the phone going to the background closes the capture', (
    tester,
  ) async {
    final rig = _Rig();
    await tester.pumpWidget(rig.app);
    await _settle(tester);

    _lifecycle(tester, AppLifecycleState.hidden);
    await _settle(tester);
    expect(rig.captureOpen, isFalse, reason: 'frames stop once hidden');
    await _end(tester, rig);
  });

  testWidgets('a route covering the screen releases the capture', (
    tester,
  ) async {
    final rig = _Rig();
    await tester.pumpWidget(rig.app);
    await _settle(tester);
    expect(rig.captureOpen, isTrue);

    rig.covered.value = true;
    await _settle(tester);
    expect(rig.captureOpen, isFalse);

    rig.covered.value = false;
    await _settle(tester);
    expect(rig.captureOpen, isTrue);
    await _end(tester, rig);
  });

  testWidgets('a fast open and close leaves no capture behind', (tester) async {
    final rig = _Rig();
    for (var i = 0; i < 4; i++) {
      rig.shown.value = true;
      await tester.pumpWidget(rig.app);
      await tester.pump();
      rig.shown.value = false;
      await tester.pump();
    }
    await _settle(tester);
    await _settle(tester);

    expect(rig.captureOpen, isFalse);
    await _end(tester, rig);
  });

  testWidgets('a call starting takes over from the preview', (tester) async {
    final rig = _Rig();
    await tester.pumpWidget(rig.app);
    await _settle(tester);

    final call =
        rig.container.read(voiceControllerProvider.notifier) as _CallController;
    call.connect();
    await _settle(tester);
    expect(rig.captureOpen, isFalse);

    call.hangUp();
    await _settle(tester);
    expect(rig.captureOpen, isTrue, reason: 'the preview comes back');
    await _end(tester, rig);
  });

  testWidgets('the call is told a level is displayed only while it is', (
    tester,
  ) async {
    final rig = _Rig();
    final shown = ValueNotifier(true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: rig.container,
        child: MaterialApp(
          home: ValueListenableBuilder<bool>(
            valueListenable: shown,
            builder: (_, on, _) => on
                ? const LevelDisplayHold(child: SizedBox())
                : const SizedBox(),
          ),
        ),
      ),
    );
    rig.container.read(voiceControllerProvider);
    await tester.pump();
    expect(rig.session.levelDisplayedCalls.last, isTrue);

    _lifecycle(tester, AppLifecycleState.inactive);
    await tester.pump();
    expect(
      rig.session.levelDisplayedCalls.last,
      isTrue,
      reason: 'an unfocused window is still on screen mid-call',
    );

    _lifecycle(tester, AppLifecycleState.hidden);
    expect(
      rig.session.levelDisplayedCalls.last,
      isFalse,
      reason: 'minimised: no frame is needed to hear it',
    );

    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    expect(rig.session.levelDisplayedCalls.last, isTrue);

    shown.value = false;
    await tester.pump();
    await tester.pump();
    expect(rig.session.levelDisplayedCalls.last, isFalse, reason: 'unmounted');
    expect(rig.container.read(levelDisplayHoldsProvider).value, 0);
    await _end(tester, rig);
  });

  testWidgets('a speaking ring keeps pulsing unfocused and stops when hidden', (
    tester,
  ) async {
    final container = ProviderContainer();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: UserAvatar(name: 'Ada', userId: null, speaking: true),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);

    _lifecycle(tester, AppLifecycleState.inactive);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue, reason: 'unfocused, on screen');

    _lifecycle(tester, AppLifecycleState.hidden);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.binding.hasScheduledFrame, isFalse);

    _lifecycle(tester, AppLifecycleState.resumed);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpWidget(const SizedBox());
    container.dispose();
  });
}
