// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The local device preferences behind `voice_settings_screen.dart`.
///
/// Split out of that file to keep it under the review budget once the
/// camera-on-join preference joined the other three; the screen is the
/// widgets, this is the state they read and write.
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'providers.dart';
import 'voice_controller.dart';

const _soundsKey = 'slimm.voice.join_leave_sounds_enabled';
const _holdMusicKey = 'slimm.voice.hold_music_enabled';
const _callRingSoundKey = 'slimm.voice.call_ring_sound_enabled';
const _qualityKey = 'slimm.voice.screen_share_quality';
const _cameraOnJoinKey = 'slimm.voice.camera_on_join';
const _pushToTalkEnabledKey = 'slimm.voice.push_to_talk_enabled';
const _pushToTalkKeyIdKey = 'slimm.voice.push_to_talk_key_id';
const _sensitivityKey = 'slimm.voice.activity_sensitivity';
const _pauseVideoUnfocusedKey = 'slimm.voice.pause_video_when_unfocused';
const _shareAudioKey = 'slimm.voice.screen_share_include_audio';
const _audioInputDeviceIdKey = 'slimm.voice.audio_input_device_id';
const _audioOutputDeviceIdKey = 'slimm.voice.audio_output_device_id';

/// The push-to-talk key options offered in Voice settings: plain letters,
/// so each is reachable while typing - the composer-focus guard is what
/// keeps that safe, not the choice of key. `V` for voice is the default.
const pushToTalkKeyOptions = [
  LogicalKeyboardKey.keyV,
  LogicalKeyboardKey.keyC,
  LogicalKeyboardKey.keyX,
  LogicalKeyboardKey.keyZ,
];

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

/// What the voice settings screen shows and edits. Every field is a pure
/// local device preference with no server truth, unlike
/// [presenceVisibilityDisplayProvider]'s session-only echo, so they are
/// persisted in [preferencesProvider] and read back on the next launch.
class VoiceSettingsState {
  const VoiceSettingsState({
    this.joinLeaveSoundsEnabled = true,
    this.callRingSoundEnabled = true,
    this.holdMusicEnabled = false,
    this.screenShareQuality = ScreenShareQuality.balanced,
    this.cameraOnJoin = false,
    this.pushToTalkEnabled = false,
    this.pushToTalkKey = LogicalKeyboardKey.keyV,
    this.voiceActivitySensitivity = 100.0,
    this.screenShareIncludeAudio = false,
    this.pauseVideoWhenUnfocused = true,
    this.audioInputDeviceId,
    this.audioOutputDeviceId,
  });

  final bool joinLeaveSoundsEnabled;

  /// Whether a DM call becoming active while this device is not already on
  /// it plays `call_ring` - a separate question from [joinLeaveSoundsEnabled],
  /// since someone may want to hear an incoming call and not care about
  /// roster chatter inside one already joined, or the other way round.
  final bool callRingSoundEnabled;

  /// Soft local music while you are the only one in a call. Off by default (owner decision 2026-09-28).
  final bool holdMusicEnabled;
  final ScreenShareQuality screenShareQuality;

  /// Whether a fresh session's first join should ask for a camera; see
  /// [VoiceSettingsController.setCameraOnJoin].
  final bool cameraOnJoin;

  /// Whether holding [pushToTalkKey] unmutes for the hold and re-mutes on
  /// release; see `push_to_talk_listener.dart`. Off by default and desktop
  /// only - keyboard focus semantics make "held" meaningless on touch.
  final bool pushToTalkEnabled;

  /// One of [pushToTalkKeyOptions]. Held while typing (a screen-reader user
  /// or anyone drafting a message may well type it), so what actually keeps
  /// this safe is the composer-focus guard, not this being a rare key.
  final LogicalKeyboardKey pushToTalkKey;

  /// 0-100, how readily the speaking indicator lights: 100 (the default)
  /// matches every call's behaviour before this setting existed, lower
  /// values require a louder reported level on top of it; see
  /// `passesActivationThreshold` in the rtc package for the exact floor and
  /// why it can only narrow the SFU's own decision, never invent one.
  final double voiceActivitySensitivity;

  /// Whether a screen share should try to publish this device's own audio
  /// alongside it. Defaults off: a stray notification chime becomes
  /// everyone's problem, where a share's video is at least something the
  /// sharer chose to show. The toggle offering this is shown only where
  /// `VoiceController.supportsScreenShareAudio` is true, and
  /// `VoiceController.setScreenShare` re-checks that same capability before
  /// honouring this value.
  final bool screenShareIncludeAudio;

  /// Whether incoming video stops while the desktop window is visible but not focused.
  final bool pauseVideoWhenUnfocused;

  /// The persisted microphone choice; null is the system default. Applied
  /// live through `VoiceControllerAudioDevicesMixin.selectAudioInputDevice`
  /// and, for a future join, through [VoiceSession]'s own room options.
  final String? audioInputDeviceId;

  /// [audioInputDeviceId]'s own counterpart for the speaker.
  final String? audioOutputDeviceId;

  VoiceSettingsState copyWith({
    bool? joinLeaveSoundsEnabled,
    bool? callRingSoundEnabled,
    bool? holdMusicEnabled,
    ScreenShareQuality? screenShareQuality,
    bool? cameraOnJoin,
    bool? pushToTalkEnabled,
    LogicalKeyboardKey? pushToTalkKey,
    double? voiceActivitySensitivity,
    bool? screenShareIncludeAudio,
    bool? pauseVideoWhenUnfocused,
    String? audioInputDeviceId,
    bool clearAudioInputDeviceId = false,
    String? audioOutputDeviceId,
    bool clearAudioOutputDeviceId = false,
  }) => VoiceSettingsState(
    joinLeaveSoundsEnabled:
        joinLeaveSoundsEnabled ?? this.joinLeaveSoundsEnabled,
    callRingSoundEnabled: callRingSoundEnabled ?? this.callRingSoundEnabled,
    holdMusicEnabled: holdMusicEnabled ?? this.holdMusicEnabled,
    screenShareQuality: screenShareQuality ?? this.screenShareQuality,
    cameraOnJoin: cameraOnJoin ?? this.cameraOnJoin,
    pushToTalkEnabled: pushToTalkEnabled ?? this.pushToTalkEnabled,
    pushToTalkKey: pushToTalkKey ?? this.pushToTalkKey,
    voiceActivitySensitivity:
        voiceActivitySensitivity ?? this.voiceActivitySensitivity,
    screenShareIncludeAudio:
        screenShareIncludeAudio ?? this.screenShareIncludeAudio,
    pauseVideoWhenUnfocused:
        pauseVideoWhenUnfocused ?? this.pauseVideoWhenUnfocused,
    audioInputDeviceId: clearAudioInputDeviceId
        ? null
        : (audioInputDeviceId ?? this.audioInputDeviceId),
    audioOutputDeviceId: clearAudioOutputDeviceId
        ? null
        : (audioOutputDeviceId ?? this.audioOutputDeviceId),
  );
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
    state = state.copyWith(
      joinLeaveSoundsEnabled: prefs.getBool(_soundsKey) ?? true,
      callRingSoundEnabled: prefs.getBool(_callRingSoundKey) ?? true,
      holdMusicEnabled: prefs.getBool(_holdMusicKey) ?? false,
      screenShareQuality: ScreenShareQuality.values
          .where((q) => q.name == storedQuality)
          .firstOrDefault(ScreenShareQuality.balanced),
      cameraOnJoin: prefs.getBool(_cameraOnJoinKey) ?? false,
      pushToTalkEnabled: prefs.getBool(_pushToTalkEnabledKey) ?? false,
      pushToTalkKey: pushToTalkKeyOptions
          .where((k) => k.keyId == storedKeyId)
          .firstOrDefault(LogicalKeyboardKey.keyV),
      voiceActivitySensitivity: prefs.getDouble(_sensitivityKey) ?? 100.0,
      screenShareIncludeAudio: prefs.getBool(_shareAudioKey) ?? false,
      pauseVideoWhenUnfocused: prefs.getBool(_pauseVideoUnfocusedKey) ?? true,
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

  Future<void> setScreenShareQuality(ScreenShareQuality quality) async {
    state = state.copyWith(screenShareQuality: quality);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setString(_qualityKey, quality.name);
  }

  Future<void> setScreenShareIncludeAudio(bool enabled) async {
    state = state.copyWith(screenShareIncludeAudio: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_shareAudioKey, enabled);
  }

  Future<void> setPauseVideoWhenUnfocused(bool enabled) async {
    state = state.copyWith(pauseVideoWhenUnfocused: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_pauseVideoUnfocusedKey, enabled);
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
    state = state.copyWith(pushToTalkEnabled: enabled);
    final prefs = await _ref.read(preferencesProvider.future);
    await prefs.setBool(_pushToTalkEnabledKey, enabled);
    _ref
        .read(voiceControllerProvider.notifier)
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
        .setVoiceActivitySensitivity(clamped);
  }
}

extension _FirstOrDefault<T> on Iterable<T> {
  T firstOrDefault(T fallback) => isEmpty ? fallback : first;
}

final voiceSettingsControllerProvider =
    StateNotifierProvider<VoiceSettingsController, VoiceSettingsState>(
      (ref) => VoiceSettingsController(ref),
    );
