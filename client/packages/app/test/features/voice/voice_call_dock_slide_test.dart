// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [VoiceCallDock]'s own entrance: it slides up once per call rather than
/// riding only the screen's shared fade, and must not replay on a rebuild
/// that leaves the same call in progress (a mute toggle, a participant
/// change) - only a genuinely new call, identified by
/// [VoiceFlags.channelId], plays it again.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/providers/voice_flags.dart';
import 'package:slimm_app/src/features/voice/screens/voice_call_dock.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart' show VoiceSessionState;

import 'voice_call_controls_harness.dart';

const _c1 = VoiceFlags(channelId: 'c1', state: VoiceSessionState.connected);
const _c1Muted = VoiceFlags(
  channelId: 'c1',
  state: VoiceSessionState.connected,
  microphoneEnabled: false,
);
const _c2 = VoiceFlags(channelId: 'c2', state: VoiceSessionState.connected);

/// Pumps [VoiceCallDock] wired to [voice], swappable in place via
/// [ValueNotifier] so a later call can rebuild the same widget - and the same
/// `State` - with a new [VoiceFlags] rather than tearing the tree down, the
/// only way to tell a rebuild apart from a fresh mount.
Future<ProviderContainer> _pump(
  WidgetTester tester,
  ValueNotifier<VoiceFlags> voice, {
  bool reduceMotion = false,
}) async {
  final container = ProviderContainer(
    overrides: [
      keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
      voiceControllerProvider.overrideWith(
        (ref) => VoiceController(ref, session: InertSession()),
      ),
    ],
  );
  addTearDown(container.dispose);

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildTheme(Brightness.light, AppTokens.light),
        home: MediaQuery(
          data: MediaQueryData(disableAnimations: reduceMotion),
          child: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: ValueListenableBuilder<VoiceFlags>(
                valueListenable: voice,
                builder: (context, value, _) => VoiceCallDock(
                  controller: container.read(voiceControllerProvider.notifier),
                  voice: value,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  return container;
}

Offset _slidePosition(WidgetTester tester) => tester
    .widget<SlideTransition>(find.byKey(VoiceCallDock.slideKey))
    .position
    .value;

void main() {
  testWidgets('the dock rises into place on first mount rather than landing '
      'settled', (tester) async {
    final voice = ValueNotifier(_c1);
    await _pump(tester, voice);
    await tester.pump();

    expect(
      _slidePosition(tester),
      isNot(Offset.zero),
      reason: 'mid-flight the rise has set off but not yet arrived',
    );
    await tester.pumpAndSettle();
    expect(_slidePosition(tester), Offset.zero);
  });

  testWidgets(
    'a rebuild mid-call - the same channel, a mic toggle - does not replay '
    'the rise',
    (tester) async {
      final voice = ValueNotifier(_c1);
      await _pump(tester, voice);
      await tester.pumpAndSettle();
      expect(_slidePosition(tester), Offset.zero);

      voice.value = _c1Muted;
      await tester.pump();

      expect(
        _slidePosition(tester),
        Offset.zero,
        reason: 'still the same call, so the rise must not restart',
      );
    },
  );

  testWidgets('joining a different channel plays the rise again', (
    tester,
  ) async {
    final voice = ValueNotifier(_c1);
    await _pump(tester, voice);
    await tester.pumpAndSettle();
    expect(_slidePosition(tester), Offset.zero);

    voice.value = _c2;
    await tester.pump();

    expect(
      _slidePosition(tester),
      isNot(Offset.zero),
      reason: 'a genuinely new call replays the entrance',
    );
    await tester.pumpAndSettle();
    expect(_slidePosition(tester), Offset.zero);
  });

  testWidgets('reduce motion lands the dock settled with no travel', (
    tester,
  ) async {
    final voice = ValueNotifier(_c1);
    await _pump(tester, voice, reduceMotion: true);
    await tester.pump();

    expect(_slidePosition(tester), Offset.zero);
    expect(tester.hasRunningAnimations, isFalse);
  });
}
