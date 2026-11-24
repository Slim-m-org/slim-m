// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tearing the container down while the saved settings are still loading is not an error.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_app/src/features/voice/providers/voice_settings_controller.dart';
import 'package:slimm_app/src/providers/providers.dart';

void main() {
  test('settings that finish loading after disposal write nothing', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final opening = Completer<SharedPreferences>();
    final container = ProviderContainer(
      overrides: [preferencesProvider.overrideWith((ref) => opening.future)],
    );
    container.read(voiceSettingsControllerProvider);
    await pumpEventQueue();

    container.dispose();
    opening.complete(prefs);
    await pumpEventQueue();
  });
}
