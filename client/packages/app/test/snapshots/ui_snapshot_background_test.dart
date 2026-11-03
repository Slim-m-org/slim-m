// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The shell over a personal background picture, and the appearance pane that
/// sets it, at desktop and phone width in dark and light. PNGs are written
/// only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/background/providers/app_background_controller.dart';
import 'package:slimm_app/src/features/background/providers/background_image_store.dart';
import 'package:slimm_app/src/features/background/providers/background_tone.dart';
import 'package:slimm_app/src/features/settings/providers/display_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import '../features/voice/voice_snapshot_fixtures.dart'
    show SnapshotVoiceController;
import '../ui_snapshot_support.dart';

const _themes = ['dark', 'light', 'halloween', 'forest'];

Future<List<Override>> _backgroundOverrides(
  WidgetTester tester, {
  bool highContrast = false,
}) async {
  final bytes = File('test/fixtures/background_forest.png').readAsBytesSync();
  final prepared = await tester.runAsync(
    () => prepareBackground(
      bytes,
      maxSide: backgroundMaxSide,
      maxSourcePixels: backgroundMaxSourcePixels,
    ),
  );
  final store = MemoryBackgroundImageStore();
  await tester.runAsync(() => store.write(prepared!.png));
  return [
    backgroundImageStoreProvider.overrideWithValue(store),
    appBackgroundControllerProvider.overrideWith(
      () => AppBackgroundController(
        AppBackgroundSettings(hasImage: true, range: prepared!.range),
      ),
    ),
    if (highContrast)
      highContrastControllerProvider.overrideWith(
        (ref) => HighContrastController(ref)..state = true,
      ),
  ];
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('channel over a background at $viewport', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/channels/c-general',
        viewport,
        _themes,
        (t) => 'background-channel-$viewport-$t',
        overrides: await _backgroundOverrides(tester),
        afterSettle: (tester) async {
          // The picture decodes outside the fake clock.
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.pump();
        },
      );
    });

    testWidgets('appearance with a background at $viewport', (tester) async {
      await renderSurfaceThemes(
        tester,
        '/settings',
        viewport,
        _themes,
        (t) => 'background-settings-$viewport-$t',
        overrides: [
          ...await _backgroundOverrides(tester),
          voiceControllerProvider.overrideWith(
            (ref) => SnapshotVoiceController(ref, const VoiceState()),
          ),
        ],
        afterSettle: (tester) async {
          await tester.tap(find.text('Appearance').first);
          await tester.pump();
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)),
          );
          await tester.pump();
        },
      );
    });
  }
}
