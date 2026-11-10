// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Records the saved voice choices at startup, so a setting that reset shows
/// up in a user's debug log.
library;

import 'package:shared_preferences/shared_preferences.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import '../features/voice/providers/noise_suppression.dart';
import '../features/voice/providers/voice_processing.dart';
import '../features/voice/providers/voice_settings_storage.dart';

/// Device ids are logged as set or unset only.
void logSavedVoiceChoices(SharedPreferences prefs) {
  final device = prefs.getString(VoiceSettingKeys.audioInputDeviceId);
  AppLog.info(
    LogTag.voice,
    'Saved voice choices loaded',
    context: {
      'noiseSuppression': prefs.getString(noiseSuppressionKey) ?? 'unset',
      'autoGain': prefs.getBool(autoGainKey)?.toString() ?? 'unset',
      'inputDevice': device == null ? 'unset' : 'set',
    },
  );
}
