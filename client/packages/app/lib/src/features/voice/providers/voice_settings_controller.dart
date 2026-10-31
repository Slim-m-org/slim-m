// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local device preferences behind `voice_settings_screen.dart`.
///
/// Split out of that file to keep it under the review budget once the
/// camera-on-join preference joined the other three; the screen is the
/// widgets, this is the state they read and write.
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart';

import '../../../audio/lounge_tracks.dart';

import '../../../providers/providers.dart';
import 'shortcut_overrides.dart' show kDefaultPushToTalkKey;
import 'voice_controller.dart';
import 'voice_settings_state.dart';

export 'voice_settings_state.dart';

const _soundsKey = 'slimm.voice.join_leave_sounds_enabled';
const _holdMusicKey = 'slimm.voice.hold_music_enabled';
const _holdMusicTrackKey = 'slimm.voice.hold_music_track';
const _holdMusicVolumeKey = 'slimm.voice.hold_music_volume';
const _callRingSoundKey = 'slimm.voice.call_ring_sound_enabled';
const _qualityKey = 'slimm.voice.screen_share_quality';
const _cameraOnJoinKey = 'slimm.voice.camera_on_join';
const _mirrorSelfViewKey = 'slimm.voice.mirror_self_view';
const _pushToTalkEnabledKey = 'slimm.voice.push_to_talk_enabled';
const _pushToTalkKeyIdKey = 'slimm.voice.push_to_talk_key_id';
const _sensitivityKey = 'slimm.voice.activity_sensitivity';
const _inputThresholdKey = 'slimm.voice.input_threshold_db';
const _inputThresholdAutoKey = 'slimm.voice.input_threshold_auto';
const _evenOutLoudKey = 'slimm.voice.even_out_loud';
// Key kept from when this paused on focus loss, so saved values carry over.
const _pauseVideoUnfocusedKey = 'slimm.voice.pause_video_when_unfocused';
const _micFallbackKey = 'slimm.voice.mic_fallback_enabled';
const _receiveQualityKey = 'slimm.voice.receive_video_quality';
const _cameraQualityKey = 'slimm.voice.camera_quality';
const _shareAudioKey = 'slimm.voice.screen_share_include_audio';
const _shareAnnotationsKey = 'slimm.voice.screen_share_allow_annotations';
const _audioInputDeviceIdKey = 'slimm.voice.audio_input_device_id';
const _audioOutputDeviceIdKey = 'slimm.voice.audio_output_device_id';

/// The persisted "join calls with your camera on" preference, read here
/// (where every other voice preference's storage key already lives) for
/// [VoiceController.restoreCameraPreference] to apply - that method stays on
/// the controller itself, `ThemeController.restore`'s own shape, since
/// that is the instance `main.dart`'s bootstrap sequence already awaits.
Future<bool> loadCameraOnJoinPreference(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(_cameraOnJoinKey) ?? false;
}

/// The persisted voice-activity sensitivity, [loadCameraOnJoinPreference]'s
/// own shape and for the same reason: [VoiceController.restoreVoiceActivitySensitivity]
/// has to reach the rtc package's session before any call is joined, not
/// only once Voice Settings has been opened this session.
Future<double> loadVoiceActivitySensitivity(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getDouble(_sensitivityKey) ?? 100.0;
}

/// The persisted input gate threshold in dBFS, for
/// `VoiceControllerInputMixin.restoreInputThreshold` to apply before a call.
Future<double> loadInputThreshold(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getDouble(_inputThresholdKey) ?? kDefaultInputThresholdDb;
}

/// Whether the gate threshold follows the room's noise floor, off until
/// chosen: `restoreInputThreshold` has to know before the first call.
Future<bool> loadInputThresholdAuto(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(_inputThresholdAutoKey) ?? false;
}

/// Whether the microphone's compressor and limiter run, for
/// `VoiceControllerInputMixin.restoreEvenOutLoudSounds`. On unless turned off:
/// it costs a fraction of a percent of one core and leaves normal speech alone.
Future<bool> loadEvenOutLoudSounds(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(_evenOutLoudKey) ?? true;
}

/// The persisted watching and camera video quality, for
/// `VoiceControllerInputMixin.restoreVideoQuality` to apply before a call.
Future<(ReceiveVideoQuality, CameraQuality)> loadVideoQualityPreferences(
  Ref ref,
) async {
  final prefs = await ref.read(preferencesProvider.future);
  return (
    _byName(
      ReceiveVideoQuality.values,
      prefs.getString(_receiveQualityKey),
      ReceiveVideoQuality.auto,
    ),
    _byName(
      CameraQuality.values,
      prefs.getString(_cameraQualityKey),
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

T _byName<T extends Enum>(List<T> values, String? name, T fallback) =>
    values.where((v) => v.name == name).firstOrNull ?? fallback;

/// The persisted push-to-talk toggle, [loadCameraOnJoinPreference]'s own
/// shape: [VoiceController.restorePushToTalkPreference] needs it before the
/// first call so a push-to-talk join starts with the mic closed, not only
/// once Voice Settings has been opened this session.
Future<bool> loadPushToTalkEnabled(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(_pushToTalkEnabledKey) ?? false;
}

/// The persisted microphone/speaker choice, [loadCameraOnJoinPreference]'s
/// own shape: `VoiceControllerAudioDevicesMixin.restoreAudioDevicePreferences`
/// needs both before the first join. Null means the system default, exactly
/// as [VoiceSettingsState.audioInputDeviceId] does.
Future<(String?, String?)> loadAudioDevicePreferences(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return (
    prefs.getString(_audioInputDeviceIdKey),
    prefs.getString(_audioOutputDeviceIdKey),
  );
}

Future<bool> loadMicFallbackEnabled(Ref ref) async {
  final prefs = await ref.read(preferencesProvider.future);
  return prefs.getBool(_micFallbackKey) ?? true;
}

class VoiceSettingsController extends StateNotifier<VoiceSettingsState> {
  VoiceSettingsController(this._ref) : super(const VoiceSettingsState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    final storedQuality = prefs.getString(_qualityKey);
    final storedKeyId = prefs.getInt(_pushToTalkKeyIdKey);
    if (prefs.getBool(_pushToTalkEnabledKey) ?? false) {
      AppLog.info(
        LogTag.voice,
        'Push-to-talk is on: read from stored settings',
      );
    }
    state = state.copyWith(
      joinLeaveSoundsEnabled: prefs.getBool(_soundsKey) ?? true,
      callRingSoundEnabled: prefs.getBool(_callRingSoundKey) ?? true,
      holdMusicEnabled: prefs.getBool(_holdMusicKey) ?? false,
      holdMusicTrack: LoungeTrack.fromName(prefs.getString(_holdMusicTrackKey)),
      holdMusicVolume:
          (prefs.getDouble(_holdMusicVolumeKey) ?? defaultHoldMusicVolume)
              .clamp(0.0, 1.0),
      screenShareQuality: screenShareQualityFromStored(storedQuality),
      receiveVideoQuality: _byName(
        ReceiveVideoQuality.values,
        prefs.getString(_receiveQualityKey),
        ReceiveVideoQuality.auto,
      ),
      cameraQuality: _byName(
        CameraQuality.values,
        prefs.getString(_cameraQualityKey),
        CameraQuality.balanced,
      ),
      cameraOnJoin: prefs.getBool(_cameraOnJoinKey) ?? false,
      mirrorSelfView: prefs.getBool(_mirrorSelfViewKey) ?? true,
      pushToTalkEnabled: prefs.getBool(_pushToTalkEnabledKey) ?? false,
      // Any key a person picked; `V` for voice until they pick one.
      pushToTalkKey: storedKeyId == null
          ? kDefaultPushToTalkKey
          : LogicalKeyboardKey.findKeyByKeyId(storedKeyId) ??
                LogicalKeyboardKey.keyV,
      voiceActivitySensitivity: prefs.getDouble(_sensitivityKey) ?? 100.0,
      inputThresholdDb:
          prefs.getDouble(_inputThresholdKey) ?? kDefaultInputThresholdDb,
      inputThresholdAuto: prefs.getBool(_inputThresholdAutoKey) ?? false,
      evenOutLoudSounds: prefs.getBool(_evenOutLoudKey) ?? true,
      screenShareIncludeAudio: prefs.getBool(_shareAudioKey) ?? false,
      screenShareAllowAnnotations: prefs.getBool(_shareAnnotationsKey) ?? false,
      pauseVideoWhenMinimised: prefs.getBool(_pauseVideoUnfocusedKey) ?? true,
      micFallbackEnabled: prefs.getBool(_micFallbackKey) ?? true,
      audioInputDeviceId: prefs.getString(_audioInputDeviceIdKey),
      audioOutputDeviceId: prefs.getString(_audioOutputDeviceIdKey),
    );
  }

  Future<void> setJoinLeaveSoundsEnabled(bool enabled) async {
    state = state.copyWith(joinLeaveSoundsEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_soundsKey, enabled);
  }

  Future<void> setCallRingSoundEnabled(bool enabled) async {
    state = state.copyWith(callRingSoundEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_callRingSoundKey, enabled);
  }

  Future<void> setHoldMusicEnabled(bool enabled) async {
    state = state.copyWith(holdMusicEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_holdMusicKey, enabled);
  }

  /// Persists the style that plays while you are alone.
  Future<void> setHoldMusicTrack(LoungeTrack track) async {
    state = state.copyWith(holdMusicTrack: track);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_holdMusicTrackKey, track.name);
  }

  Future<void> setHoldMusicVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    state = state.copyWith(holdMusicVolume: clamped);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(_holdMusicVolumeKey, clamped);
  }

  Future<void> setScreenShareResolution(ScreenShareResolution r) =>
      setScreenShareQuality(
        ScreenShareQuality(r, state.screenShareQuality.frameRate),
      );

  Future<void> setScreenShareFps(ScreenShareFps f) => setScreenShareQuality(
    ScreenShareQuality(state.screenShareQuality.resolution, f),
  );

  Future<void> setScreenShareQuality(ScreenShareQuality quality) async {
    state = state.copyWith(screenShareQuality: quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_qualityKey, quality.id);
  }

  /// Persists and applies live: a call may already be open this session.
  Future<void> setReceiveVideoQuality(ReceiveVideoQuality quality) async {
    state = state.copyWith(receiveVideoQuality: quality);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setReceiveVideoQuality(quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_receiveQualityKey, quality.name);
  }

  /// [setReceiveVideoQuality]'s counterpart; a live camera restarts shortly after.
  Future<void> setCameraQuality(CameraQuality quality) async {
    state = state.copyWith(cameraQuality: quality);
    _ref.read(voiceControllerProvider.notifier).input.setCameraQuality(quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_cameraQualityKey, quality.name);
  }

  Future<void> setScreenShareIncludeAudio(bool enabled) async {
    state = state.copyWith(screenShareIncludeAudio: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_shareAudioKey, enabled);
  }

  Future<void> setScreenShareAllowAnnotations(bool enabled) async {
    state = state.copyWith(screenShareAllowAnnotations: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_shareAnnotationsKey, enabled);
  }

  Future<void> setMirrorSelfView(bool enabled) async {
    state = state.copyWith(mirrorSelfView: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_mirrorSelfViewKey, enabled);
  }

  Future<void> setPauseVideoWhenMinimised(bool enabled) async {
    state = state.copyWith(pauseVideoWhenMinimised: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_pauseVideoUnfocusedKey, enabled);
  }

  Future<void> setMicFallbackEnabled(bool enabled) async {
    state = state.copyWith(micFallbackEnabled: enabled);
    _ref
        .read(voiceControllerProvider.notifier)
        .devices
        .setMicFallbackEnabled(enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_micFallbackKey, enabled);
  }

  /// Persists the microphone choice and applies it live, [setCameraOnJoin]'s
  /// own reasoning: a call may already be open this session, and the
  /// persisted copy alone only reaches a *future* launch's
  /// `VoiceControllerAudioDevicesMixin.restoreAudioDevicePreferences`. Null
  /// clears back to the system default.
  Future<void> setAudioInputDevice(AudioDevice? device) async {
    state = state.copyWith(
      audioInputDeviceId: device?.id,
      clearAudioInputDeviceId: device == null,
    );
    final prefs = await _ref.read(preferencesProvider.future);
    if (device == null) {
      await prefs.remove(_audioInputDeviceIdKey);
    } else {
      await prefs.setString(_audioInputDeviceIdKey, device.id);
    }
    await _ref
        .read(voiceControllerProvider.notifier)
        .devices
        .selectAudioInputDevice(device);
  }

  /// [setAudioInputDevice]'s counterpart for the speaker.
  Future<void> setAudioOutputDevice(AudioDevice? device) async {
    state = state.copyWith(
      audioOutputDeviceId: device?.id,
      clearAudioOutputDeviceId: device == null,
    );
    final prefs = await _ref.read(preferencesProvider.future);
    if (device == null) {
      await prefs.remove(_audioOutputDeviceIdKey);
    } else {
      await prefs.setString(_audioOutputDeviceIdKey, device.id);
    }
    await _ref
        .read(voiceControllerProvider.notifier)
        .devices
        .selectAudioOutputDevice(device);
  }

  /// Persists the "join with camera on" preference and, since a call may
  /// already be joinable this same session, applies it to
  /// [VoiceController.setCameraPreference] immediately - the persisted copy
  /// is only what a *future* launch's [VoiceController.restoreCameraPreference]
  /// reads, and would otherwise leave this session's own next join stale
  /// until a restart.
  Future<void> setCameraOnJoin(bool enabled) async {
    state = state.copyWith(cameraOnJoin: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_cameraOnJoinKey, enabled);
    _ref.read(voiceControllerProvider.notifier).setCameraPreference(enabled);
  }

  /// Persists the toggle and applies it live, [setCameraOnJoin]'s reasoning:
  /// a call may already be open, so enabling must close its mic now rather
  /// than only affecting the next launch's [VoiceController.restorePushToTalkPreference].
  Future<void> setPushToTalkEnabled(bool enabled) async {
    AppLog.info(
      LogTag.voice,
      'Push-to-talk turned ${enabled ? 'on' : 'off'} by the settings toggle',
    );
    state = state.copyWith(pushToTalkEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_pushToTalkEnabledKey, enabled);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setPushToTalkPreference(enabled);
  }

  Future<void> setPushToTalkKey(LogicalKeyboardKey key) async {
    state = state.copyWith(pushToTalkKey: key);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setInt(_pushToTalkKeyIdKey, key.keyId);
  }

  /// Persists the sensitivity and applies it live, [setCameraOnJoin]'s own
  /// reasoning: a call may already be open this session, and the persisted
  /// copy alone only reaches a *future* launch's
  /// [VoiceController.restoreVoiceActivitySensitivity].
  Future<void> setVoiceActivitySensitivity(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    state = state.copyWith(voiceActivitySensitivity: clamped);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(_sensitivityKey, clamped);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setVoiceActivitySensitivity(clamped);
  }

  /// Persists the gate threshold and applies it live.
  Future<void> setInputThreshold(double db) async {
    final clamped = db.clamp(kInputFloorDb, 0.0);
    state = state.copyWith(inputThresholdDb: clamped);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(_inputThresholdKey, clamped);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setInputThreshold(clamped);
  }

  /// Turning it off keeps wherever the threshold had got to as the manual one.
  Future<void> setInputThresholdAuto(bool enabled) async {
    final voice = _ref.read(voiceControllerProvider.notifier);
    final kept = enabled ? null : voice.input.inputThresholdDb;
    state = state.copyWith(inputThresholdAuto: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_inputThresholdAutoKey, enabled);
    if (kept != null) await setInputThreshold(kept);
    voice.input.setInputThresholdAuto(enabled);
  }

  /// Persists the compressor and limiter choice and applies it live.
  Future<void> setEvenOutLoudSounds(bool enabled) async {
    state = state.copyWith(evenOutLoudSounds: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_evenOutLoudKey, enabled);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setEvenOutLoudSounds(enabled);
  }
}

final voiceSettingsControllerProvider =
    StateNotifierProvider<VoiceSettingsController, VoiceSettingsState>(
      (ref) => VoiceSettingsController(ref),
    );
