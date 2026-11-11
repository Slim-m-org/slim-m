// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Camera surfaces in a voice call: the grid with camera tiles, desktop and
/// phone, in both themes. PNGs are written only under SLIMM_UI_SNAPSHOTS=1.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_controller.dart';

import '../features/voice/voice_snapshot_fixtures.dart';
import '../ui_snapshot_support.dart';

List<Override> _call() => [
  voiceControllerProvider.overrideWith(
    (ref) => SnapshotVoiceController(ref, localCameraCallState),
  ),
];

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final entry in const {
    'desktop': 'desktop',
    'phone': 'phone-portrait',
  }.entries) {
    testWidgets('local camera call on ${entry.key}', (tester) async {
      if (entry.key == 'phone') {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      }
      try {
        await renderSurface(
          tester,
          '/channels/c-main',
          entry.value,
          darkAndLight,
          'camera-call-${entry.key}-$darkAndLight',
          overrides: _call(),
          allowNoText: true,
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });
  }
}
