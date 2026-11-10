// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The loudspeaker or earpiece choice on a phone that lists no outputs.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/speaker_route_provider.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../support/mid_flight_capture.dart';
import 'voice_settings_screen_harness.dart';

const _label = 'Play calls through the loudspeaker';
const _key = 'slimm.voice.speaker_preferred';

Finder get _toggle =>
    find.byWidgetPredicate((w) => w is AppToggle && w.semanticLabel == _label);

Future<List<Override>> _overrides(
  FakeSettingsSession session,
  List<bool> applied, {
  required bool supported,
}) async => [
  voiceControllerProvider.overrideWith(
    (ref) => VoiceController(ref, session: session),
  ),
  speakerRouteProvider.overrideWithValue(
    SpeakerRoute(supported: supported, apply: (on) async => applied.add(on)),
  ),
];

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await expectSettled(tester, 'voice settings speaker route');
}

Future<void> _open(WidgetTester tester, List<Override> overrides) async {
  // Tall enough that every row is built, so nothing needs scrolling to.
  tester.view.physicalSize = const Size(900, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    wrap(const VoiceSettingsBody(), overrides: overrides),
  );
  await _settle(tester);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('a phone with no output picker can pick the earpiece', (
    tester,
  ) async {
    final applied = <bool>[];
    final session = FakeSettingsSession(supportsAudioOutputSelection: false);
    await _open(tester, await _overrides(session, applied, supported: true));
    expect(tester.widget<AppToggle>(_toggle).value, isTrue);
    expect(find.text('Off plays calls through the earpiece.'), findsOneWidget);
    expect(find.text('Output device'), findsNothing);

    await tester.tap(_toggle);
    await _settle(tester);

    expect(tester.widget<AppToggle>(_toggle).value, isFalse);
    expect(applied, [false]);
    expect((await SharedPreferences.getInstance()).getBool(_key), isFalse);
  });

  testWidgets('a platform with an output picker keeps the picker', (
    tester,
  ) async {
    final session = FakeSettingsSession();
    await _open(tester, await _overrides(session, [], supported: true));

    expect(_toggle, findsNothing);
    expect(find.text('Output device'), findsOneWidget);
  });

  testWidgets('a platform that cannot switch shows no toggle', (tester) async {
    final session = FakeSettingsSession(supportsAudioOutputSelection: false);
    await _open(tester, await _overrides(session, [], supported: false));

    expect(_toggle, findsNothing);
    expect(
      find.text(
        'This platform always plays a call through its default output.',
      ),
      findsOneWidget,
    );
  });

  for (final saved in [false, null]) {
    test(
      'startup applies a saved earpiece choice, not the default ($saved)',
      () async {
        final applied = <bool>[];
        SharedPreferences.setMockInitialValues({
          if (saved != null) _key: saved,
        });
        final container = ProviderContainer(
          overrides: await _overrides(
            FakeSettingsSession(),
            applied,
            supported: true,
          ),
        );
        addTearDown(container.dispose);

        await container
            .read(voiceControllerProvider.notifier)
            .devices
            .restoreSpeakerPreference();

        expect(applied, saved == null ? isEmpty : [false]);
      },
    );
  }
}
