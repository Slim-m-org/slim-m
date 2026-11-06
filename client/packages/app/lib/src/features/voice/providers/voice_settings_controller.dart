// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local device preferences behind `voice_settings_screen.dart`.
///
/// Split out of that file to keep it under the review budget once the
/// camera-on-join preference joined the other three; the screen is the
/// widgets, this is the state they read and write.
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart' show OverlayCorner;
import 'package:slimm_rtc/rtc.dart';

import '../../../audio/lounge_tracks.dart';

import '../../../providers/providers.dart';
import 'shortcut_overrides.dart' show kDefaultPushToTalkKey;
import 'voice_controller.dart';
import 'speaker_route_provider.dart';
import 'voice_settings_state.dart';
import 'voice_settings_storage.dart';

export 'voice_settings_state.dart';
export 'voice_settings_storage.dart';

class VoiceSettingsController extends StateNotifier<VoiceSettingsState> {
  VoiceSettingsController(this._ref) : super(const VoiceSettingsState()) {
    _load();
  }

  final Ref _ref;

  Future<void> _load() async {
    final prefs = await _ref.read(preferencesProvider.future);
    final storedQuality = prefs.getString(VoiceSettingKeys.quality);
    final storedKeyId = prefs.getInt(VoiceSettingKeys.pushToTalkKeyId);
    if (prefs.getBool(VoiceSettingKeys.pushToTalkEnabled) ?? false) {
      AppLog.info(
        LogTag.voice,
        'Push-to-talk is on: read from stored settings',
      );
    }
    state = state.copyWith(
      joinLeaveSoundsEnabled: prefs.getBool(VoiceSettingKeys.sounds) ?? true,
      callRingSoundEnabled:
          prefs.getBool(VoiceSettingKeys.callRingSound) ?? true,
      holdMusicEnabled: prefs.getBool(holdMusicEnabledKey) ?? false,
      holdMusicTrack: LoungeTrack.fromName(
        prefs.getString(VoiceSettingKeys.holdMusicTrack),
      ),
      holdMusicVolume:
          (prefs.getDouble(VoiceSettingKeys.holdMusicVolume) ??
                  defaultHoldMusicVolume)
              .clamp(0.0, 1.0),
      screenShareQuality: screenShareQualityFromStored(storedQuality),
      receiveVideoQuality: enumByName(
        ReceiveVideoQuality.values,
        prefs.getString(VoiceSettingKeys.receiveQuality),
        ReceiveVideoQuality.auto,
      ),
      cameraQuality: enumByName(
        CameraQuality.values,
        prefs.getString(VoiceSettingKeys.cameraQuality),
        CameraQuality.balanced,
      ),
      cameraOnJoin: prefs.getBool(VoiceSettingKeys.cameraOnJoin) ?? false,
      mirrorSelfView: prefs.getBool(VoiceSettingKeys.mirrorSelfView) ?? true,
      pushToTalkEnabled:
          prefs.getBool(VoiceSettingKeys.pushToTalkEnabled) ?? false,
      // Any key a person picked; `V` for voice until they pick one.
      pushToTalkKey: storedKeyId == null
          ? kDefaultPushToTalkKey
          : LogicalKeyboardKey.findKeyByKeyId(storedKeyId) ??
                LogicalKeyboardKey.keyV,
      voiceActivitySensitivity:
          prefs.getDouble(VoiceSettingKeys.sensitivity) ?? 100.0,
      inputThresholdDb:
          prefs.getDouble(VoiceSettingKeys.inputThreshold) ??
          kDefaultInputThresholdDb,
      inputThresholdAuto:
          prefs.getBool(VoiceSettingKeys.inputThresholdAuto) ?? false,
      evenOutLoudSounds: prefs.getBool(VoiceSettingKeys.evenOutLoud) ?? true,
      screenShareIncludeAudio:
          prefs.getBool(VoiceSettingKeys.shareAudio) ?? false,
      screenShareAllowAnnotations:
          prefs.getBool(VoiceSettingKeys.shareAnnotations) ?? false,
      callOverlayEnabled: prefs.getBool(VoiceSettingKeys.callOverlay) ?? false,
      callOverlayCorner: enumByName(
        OverlayCorner.values,
        prefs.getString(VoiceSettingKeys.callOverlayCorner),
        OverlayCorner.topLeft,
      ),
      callOverlayScreen: () =>
          prefs.getString(VoiceSettingKeys.callOverlayScreen),
      pauseVideoWhenMinimised:
          prefs.getBool(VoiceSettingKeys.pauseVideoUnfocused) ?? true,
      micFallbackEnabled: prefs.getBool(VoiceSettingKeys.micFallback) ?? true,
      speakerPreferred:
          prefs.getBool(VoiceSettingKeys.speakerPreferred) ?? true,
      audioInputDeviceId: prefs.getString(VoiceSettingKeys.audioInputDeviceId),
      audioOutputDeviceId: prefs.getString(
        VoiceSettingKeys.audioOutputDeviceId,
      ),
    );
  }

  Future<void> setJoinLeaveSoundsEnabled(bool enabled) async {
    state = state.copyWith(joinLeaveSoundsEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.sounds, enabled);
  }

  Future<void> setCallRingSoundEnabled(bool enabled) async {
    state = state.copyWith(callRingSoundEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.callRingSound, enabled);
  }

  Future<void> setHoldMusicEnabled(bool enabled) async {
    await applyHoldMusicEnabled(enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(holdMusicUnsentKey, true);
    try {
      await _ref.read(apiProvider).setHoldMusic(enabled);
      await prefs.remove(holdMusicUnsentKey);
    } catch (error, stack) {
      reportFailure(
        LogTag.voice,
        'save hold music to the account',
        error,
        stack,
      );
    }
  }

  /// Stores a value without sending it, for one the account already holds.
  Future<void> applyHoldMusicEnabled(bool enabled) async {
    state = state.copyWith(holdMusicEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(holdMusicEnabledKey, enabled);
  }

  /// Persists the style that plays while you are alone.
  Future<void> setHoldMusicTrack(LoungeTrack track) async {
    state = state.copyWith(holdMusicTrack: track);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(VoiceSettingKeys.holdMusicTrack, track.name);
  }

  Future<void> setHoldMusicVolume(double volume) async {
    final clamped = volume.clamp(0.0, 1.0);
    state = state.copyWith(holdMusicVolume: clamped);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(VoiceSettingKeys.holdMusicVolume, clamped);
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
    await prefs.setString(VoiceSettingKeys.quality, quality.id);
  }

  /// Persists and applies live: a call may already be open this session.
  Future<void> setReceiveVideoQuality(ReceiveVideoQuality quality) async {
    state = state.copyWith(receiveVideoQuality: quality);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setReceiveVideoQuality(quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(VoiceSettingKeys.receiveQuality, quality.name);
  }

  /// [setReceiveVideoQuality]'s counterpart; a live camera restarts shortly after.
  Future<void> setCameraQuality(CameraQuality quality) async {
    state = state.copyWith(cameraQuality: quality);
    _ref.read(voiceControllerProvider.notifier).input.setCameraQuality(quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(VoiceSettingKeys.cameraQuality, quality.name);
  }

  Future<void> setScreenShareIncludeAudio(bool enabled) async {
    state = state.copyWith(screenShareIncludeAudio: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.shareAudio, enabled);
  }

  Future<void> setScreenShareAllowAnnotations(bool enabled) async {
    state = state.copyWith(screenShareAllowAnnotations: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.shareAnnotations, enabled);
  }

  Future<void> setCallOverlayEnabled(bool enabled) async {
    state = state.copyWith(callOverlayEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.callOverlay, enabled);
  }

  Future<void> setCallOverlayCorner(OverlayCorner corner) async {
    state = state.copyWith(callOverlayCorner: corner);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(VoiceSettingKeys.callOverlayCorner, corner.name);
  }

  /// Null goes back to following the app window.
  Future<void> setCallOverlayScreen(String? screen) async {
    state = state.copyWith(callOverlayScreen: () => screen);
    final prefs = await _ref.read(preferencesProvider.future);
    if (screen == null) {
      await prefs.remove(VoiceSettingKeys.callOverlayScreen);
    } else {
      await prefs.setString(VoiceSettingKeys.callOverlayScreen, screen);
    }
  }

  Future<void> setMirrorSelfView(bool enabled) async {
    state = state.copyWith(mirrorSelfView: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.mirrorSelfView, enabled);
  }

  Future<void> setPauseVideoWhenMinimised(bool enabled) async {
    state = state.copyWith(pauseVideoWhenMinimised: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.pauseVideoUnfocused, enabled);
  }

  Future<void> setMicFallbackEnabled(bool enabled) async {
    state = state.copyWith(micFallbackEnabled: enabled);
    _ref
        .read(voiceControllerProvider.notifier)
        .devices
        .setMicFallbackEnabled(enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.micFallback, enabled);
  }

  Future<void> setSpeakerPreferred(bool preferred) async {
    state = state.copyWith(speakerPreferred: preferred);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.speakerPreferred, preferred);
    await applySpeakerPreference(_ref.read(speakerRouteProvider), preferred);
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
      await prefs.remove(VoiceSettingKeys.audioInputDeviceId);
    } else {
      await prefs.setString(VoiceSettingKeys.audioInputDeviceId, device.id);
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
      await prefs.remove(VoiceSettingKeys.audioOutputDeviceId);
    } else {
      await prefs.setString(VoiceSettingKeys.audioOutputDeviceId, device.id);
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
    await prefs.setBool(VoiceSettingKeys.cameraOnJoin, enabled);
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
    await prefs.setBool(VoiceSettingKeys.pushToTalkEnabled, enabled);
    _ref
        .read(voiceControllerProvider.notifier)
        .input
        .setPushToTalkPreference(enabled);
  }

  Future<void> setPushToTalkKey(LogicalKeyboardKey key) async {
    state = state.copyWith(pushToTalkKey: key);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setInt(VoiceSettingKeys.pushToTalkKeyId, key.keyId);
  }

  /// Persists the sensitivity and applies it live, [setCameraOnJoin]'s own
  /// reasoning: a call may already be open this session, and the persisted
  /// copy alone only reaches a *future* launch's
  /// [VoiceController.restoreVoiceActivitySensitivity].
  Future<void> setVoiceActivitySensitivity(double value) async {
    final clamped = value.clamp(0.0, 100.0);
    state = state.copyWith(voiceActivitySensitivity: clamped);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setDouble(VoiceSettingKeys.sensitivity, clamped);
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
    await prefs.setDouble(VoiceSettingKeys.inputThreshold, clamped);
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
    await prefs.setBool(VoiceSettingKeys.inputThresholdAuto, enabled);
    if (kept != null) await setInputThreshold(kept);
    voice.input.setInputThresholdAuto(enabled);
  }

  /// Persists the compressor and limiter choice and applies it live.
  Future<void> setEvenOutLoudSounds(bool enabled) async {
    state = state.copyWith(evenOutLoudSounds: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(VoiceSettingKeys.evenOutLoud, enabled);
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
