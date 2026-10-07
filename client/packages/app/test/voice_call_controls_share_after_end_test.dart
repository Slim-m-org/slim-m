// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The call ending while the screen source picker is open must not start a
/// share once a source is chosen: there is no call left to publish into.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_app/src/providers/voice_controller.dart';
import 'package:slimm_app/src/providers/voice_flags.dart';
import 'package:slimm_app/src/screens/voice_call_controls.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/platform.dart';
import 'package:slimm_rtc/rtc.dart';

import 'voice_call_controls_harness.dart';

const _sources = [
  ScreenShareSource(id: '1', name: 'Screen 1'),
  ScreenShareSource(id: '2', name: 'Screen 2'),
];

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('choosing a source after the call ended starts no share', (
    tester,
  ) async {
    final session = InertSession(
      needsSource: true,
      sources: Future.value(_sources),
    );
    final container = ProviderContainer(
      overrides: [
        keyStoreProvider.overrideWithValue(InMemoryKeyStore()),
        voiceControllerProvider.overrideWith(
          (ref) => VoiceController(ref, session: session),
        ),
      ],
    );
    addTearDown(container.dispose);
    final flags = ValueNotifier(
      const VoiceFlags(state: VoiceSessionState.connected),
    );
    addTearDown(flags.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: Scaffold(
            body: ValueListenableBuilder<VoiceFlags>(
              valueListenable: flags,
              builder: (_, voice, _) => CallControls(
                controller: container.read(voiceControllerProvider.notifier),
                voice: voice,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip(RegExp(r'^Share a screen')));
    await tester.pumpAndSettle();
    expect(find.text('Screen 2'), findsOneWidget);

    flags.value = const VoiceFlags();
    await tester.pump();
    await tester.tap(find.text('Screen 2'));
    await tester.pumpAndSettle();

    expect(session.screenShareCalls, isEmpty);
  });
}
