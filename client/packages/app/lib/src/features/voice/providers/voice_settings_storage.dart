// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Where voice preferences are stored, and the reads a call needs before
/// Voice Settings has ever been opened.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart'
    show SharedPreferences;
import 'package:slimm_api/api.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import 'voice_settings_state.dart';

/// Where each voice preference is stored.
abstract final class VoiceSettingKeys {
  static const sounds = 'slimm.voice.join_leave_sounds_enabled';
  static const holdMusicTrack = 'slimm.voice.hold_music_track';
  static const holdMusicVolume = 'slimm.voice.hold_music_volume';
  static const callRingSound = 'slimm.voice.call_ring_sound_enabled';
  static const quality = 'slimm.voice.screen_share_quality';
  static const cameraOnJoin = 'slimm.voice.camera_on_join';
  static const mirrorSelfView = 'slimm.voice.mirror_self_view';
  static const pushToTalkEnabled = 'slimm.voice.push_to_talk_enabled';
  static const pushToTalkKeyId = 'slimm.voice.push_to_talk_key_id';
  static const sensitivity = 'slimm.voice.activity_sensitivity';
  static const inputThreshold = 'slimm.voice.input_threshold_db';
  static const inputThresholdAuto = 'slimm.voice.input_threshold_auto';
  static const evenOutLoud = 'slimm.voice.even_out_loud';
  // Key kept from when this paused on focus loss, so saved values carry over.
  static const pauseVideoUnfocused = 'slimm.voice.pause_video_when_unfocused';
  static const micFallback = 'slimm.voice.mic_fallback_enabled';
  static const speakerPreferred = 'slimm.voice.speaker_preferred';
  static const receiveQuality = 'slimm.voice.receive_video_quality';
  static const cameraQuality = 'slimm.voice.camera_quality';
  static const cameraReach = 'slimm.voice.camera_reach';
  static const shareAudio = 'slimm.voice.screen_share_include_audio';
  static const shareAnnotations = 'slimm.voice.screen_share_allow_annotations';
  static const callOverlay = 'slimm.voice.call_overlay_enabled';
  static const callOverlayCorner = 'slimm.voice.call_overlay_corner';
  static const callOverlayScreen = 'slimm.voice.call_overlay_screen';
  static const audioInputDeviceId = 'slimm.voice.audio_input_device_id';
  static const audioOutputDeviceId = 'slimm.voice.audio_output_device_id';
}

const holdMusicEnabledKey = 'slimm.voice.hold_music_enabled';

/// Set while a toggle has not reached the account, so a resume sends it rather than overwriting it.
const holdMusicUnsentKey = 'slimm.voice.hold_music_unsent';

/// The persisted "join calls with your camera on" preference, read here
/// (where every other voice preference's storage key already lives) for
/// [VoiceController.restoreCameraPreference] to apply - that method stays on
/// the controller itself, `ThemeController.restore`'s own shape, since
/// that is the instance `main.dart`'s bootstrap sequence already awaits.
Future<bool> loadCameraOnJoinPreference(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.cameraOnJoin) ?? false;
}

/// The persisted voice-activity sensitivity, [loadCameraOnJoinPreference]'s
/// own shape and for the same reason: [VoiceController.restoreVoiceActivitySensitivity]
/// has to reach the rtc package's session before any call is joined, not
/// only once Voice Settings has been opened this session.
Future<double> loadVoiceActivitySensitivity(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getDouble(VoiceSettingKeys.sensitivity) ?? 100.0;
}

/// The persisted input gate threshold in dBFS, for
/// `VoiceControllerInputMixin.restoreInputThreshold` to apply before a call.
Future<double> loadInputThreshold(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getDouble(VoiceSettingKeys.inputThreshold) ??
      kDefaultInputThresholdDb;
}

/// Whether the gate threshold follows the room's noise floor, off until
/// chosen: `restoreInputThreshold` has to know before the first call.
Future<bool> loadInputThresholdAuto(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.inputThresholdAuto) ?? false;
}

/// Whether the microphone's compressor and limiter run, for
/// `VoiceControllerInputMixin.restoreEvenOutLoudSounds`. On unless turned off:
/// it costs a fraction of a percent of one core and leaves normal speech alone.
Future<bool> loadEvenOutLoudSounds(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.evenOutLoud) ?? true;
}

/// The persisted watching and camera video quality, for
/// `VoiceControllerInputMixin.restoreVideoQuality` to apply before a call.
Future<(ReceiveVideoQuality, CameraQuality)> loadVideoQualityPreferences(
  Ref ref,
) async {
  final prefs = await ref.read(preferencesProvider.future);
  return (
    enumByName(
      ReceiveVideoQuality.values,
      prefs.getString(VoiceSettingKeys.receiveQuality),
      ReceiveVideoQuality.auto,
    ),
    enumByName(
      CameraQuality.values,
      prefs.getString(VoiceSettingKeys.cameraQuality),
      CameraQuality.balanced,
    ),
  );
}

/// The pair a stored value names, reading the pre-split tier names too.
ScreenShareQuality screenShareQualityFromStored(String? stored) {
  const legacy = {
    'smooth': '720p60',
    'balanced': '1080p30',
    'crisp': '1440p15',
  };
  return ScreenShareQuality.fromId(legacy[stored] ?? stored) ??
      ScreenShareQuality.standard;
}

/// The value of [values] named [name], or [fallback].
T enumByName<T extends Enum>(List<T> values, String? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

/// The persisted push-to-talk toggle, [loadCameraOnJoinPreference]'s own
/// shape: [VoiceController.restorePushToTalkPreference] needs it before the
/// first call so a push-to-talk join starts with the mic closed, not only
/// once Voice Settings has been opened this session.
Future<bool> loadPushToTalkEnabled(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.pushToTalkEnabled) ?? false;
}

/// The persisted microphone/speaker choice, [loadCameraOnJoinPreference]'s
/// own shape: `VoiceControllerAudioDevicesMixin.restoreAudioDevicePreferences`
/// needs both before the first join. Null means the system default, exactly
/// as [VoiceSettingsState.audioInputDeviceId] does.
Future<(String?, String?)> loadAudioDevicePreferences(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return (
    prefs.getString(VoiceSettingKeys.audioInputDeviceId),
    prefs.getString(VoiceSettingKeys.audioOutputDeviceId),
  );
}

/// The saved microphone id from [prefs], null for the system default.
String? savedAudioInputId(SharedPreferences prefs) =>
    prefs.getString(VoiceSettingKeys.audioInputDeviceId);

Future<bool> loadMicFallbackEnabled(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.micFallback) ?? true;
}

Future<bool> loadSpeakerPreferred(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(VoiceSettingKeys.speakerPreferred) ?? true;
}

/// A refused route change leaves the choice saved and the call as it was.
Future<void> applySpeakerPreference(SpeakerRoute route, bool preferred) async {
  try {
    await route.set(preferred);
  } on Object catch (e, stack) {
    AppLog.swallowed(LogTag.voice, 'Could not route the call audio', e, stack);
  }
}
