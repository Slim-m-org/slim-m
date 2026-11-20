// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The soundboard volume and mute: persisted, bound to the picker's row, and
/// offered under Speaker in voice settings, where settings search finds both.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_clips.dart';
import 'package:slimm_app/src/features/voice/providers/soundboard_settings.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';
import 'package:slimm_app/src/features/voice/screens/voice_settings_screen.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_picker.dart';
import 'package:slimm_app/src/features/voice/widgets/soundboard_volume_row.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_platform/testing.dart';

import '../../support/async_wait.dart';
import 'voice_settings_screen_harness.dart';

const _clip = api.SoundClip(
  id: 'c1',
  name: 'Airhorn',
  durationMs: 1000,
  uploaderId: null,
  createdAt: 1,
);

ProviderContainer _container() => ProviderContainer(
  overrides: [keyStoreProvider.overrideWithValue(InMemoryKeyStore())],
);

Finder get _muteButton => find.byKey(SoundboardVolumeRow.muteKey);

Finder get _toggle => find.byWidgetPredicate(
  (w) =>
      w is AppToggle &&
      w.semanticLabel == 'Hear soundboard clips played in a call',
);

Future<ProviderContainer> _pumpPicker(WidgetTester tester) async {
  final container = _container();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: ProviderScope(
        overrides: [
          soundClipsProvider.overrideWith((ref) async => [_clip]),
        ],
        child: MaterialApp(
          theme: buildTheme(Brightness.light, AppTokens.light),
          home: const Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: soundboardMenuWidth,
                child: SoundboardPicker(channelId: 'c1'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await pumpFrames(tester);
  return container;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('the volume defaults to full, persists, and clamps', () async {
    final container = _container();
    addTearDown(container.dispose);
    await container.read(preferencesProvider.future);
    expect(container.read(soundboardVolumeProvider), 1.0);

    final volume = container.read(soundboardVolumeProvider.notifier);
    await volume.setVolume(0.4);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getDouble(soundboardVolumeKey), 0.4);
    await volume.setVolume(3);
    expect(container.read(soundboardVolumeProvider), 1.0);
  });

  test('a saved volume is read back', () async {
    SharedPreferences.setMockInitialValues({soundboardVolumeKey: 0.25});
    final container = _container();
    addTearDown(container.dispose);
    await container.read(preferencesProvider.future);
    expect(container.read(soundboardVolumeProvider), 0.25);
  });

  testWidgets('the picker mute button flips the same switch as settings', (
    tester,
  ) async {
    final container = await _pumpPicker(tester);
    expect(container.read(soundboardSoundsProvider), isTrue);

    await tester.tap(_muteButton);
    await pumpFrames(tester);
    expect(container.read(soundboardSoundsProvider), isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(soundboardSoundsEnabledKey), isFalse);

    await tester.tap(_muteButton);
    await pumpFrames(tester);
    expect(container.read(soundboardSoundsProvider), isTrue);
  });

  testWidgets('the picker slider sets the volume and mute keeps it', (
    tester,
  ) async {
    final container = await _pumpPicker(tester);
    final slider = find.byKey(SoundboardVolumeRow.sliderKey);
    final rect = tester.getRect(slider);
    await tester.tapAt(Offset(rect.left + rect.width * 0.5, rect.center.dy));
    await pumpFrames(tester);
    final set = container.read(soundboardVolumeProvider);
    expect(set, inInclusiveRange(0.3, 0.7));

    await tester.tap(_muteButton);
    await pumpFrames(tester);
    expect(tester.widget<AppSlider>(slider).onChanged, isNull);
    expect(container.read(soundboardVolumeProvider), set);
  });

  testWidgets('voice settings hold the switch and the volume slider', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const VoiceSettingsBody(),
        overrides: [
          voiceControllerProvider.overrideWith(
            (ref) => VoiceController(ref, session: FakeSettingsSession()),
          ),
        ],
      ),
    );
    await pumpFrames(tester);
    final slider = find.byKey(soundboardVolumeSliderKey);
    await tester.scrollUntilVisible(
      slider,
      200,
      scrollable: find.byWidgetPredicate((w) => w is Scrollable).first,
    );
    expect(find.text('Soundboard sounds'), findsOneWidget);
    expect(find.text('Soundboard volume'), findsOneWidget);
    expect(tester.widget<AppToggle>(_toggle).value, isTrue);

    await tester.ensureVisible(_toggle);
    await tester.tap(_toggle);
    await pumpFrames(tester);
    expect(tester.widget<AppToggle>(_toggle).value, isFalse);
    expect(slider, findsNothing, reason: 'hidden while muted');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(soundboardSoundsEnabledKey), isFalse);
  });

  test('settings search finds both under voice, none under notifications', () {
    for (final term in ['soundboard sounds', 'soundboard volume']) {
      final hits = searchSettings(term, personalSettingsIndex);
      expect(hits, isNotEmpty);
      expect(hits.map((e) => e.pane), everyElement('voice'));
    }
  });
}
