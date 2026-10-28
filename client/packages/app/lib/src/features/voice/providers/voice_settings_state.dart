// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What [VoiceSettingsController] holds; see `voice_settings_controller.dart`.
library;

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:slimm_rtc/rtc.dart';

import '../../../audio/lounge_tracks.dart';
import 'shortcut_overrides.dart' show kDefaultPushToTalkKey;

/// What the voice settings screen shows and edits. Every field is a pure
/// local device preference with no server truth, unlike
/// [presenceVisibilityDisplayProvider]'s session-only echo, so they are
/// persisted in [preferencesProvider] and read back on the next launch.
class VoiceSettingsState {
  const VoiceSettingsState({
    this.joinLeaveSoundsEnabled = true,
    this.callRingSoundEnabled = true,
    this.holdMusicEnabled = false,
    this.holdMusicTrack = LoungeTrack.lofi,
    this.holdMusicVolume = defaultHoldMusicVolume,
    this.screenShareQuality = ScreenShareQuality.standard,
    this.receiveVideoQuality = ReceiveVideoQuality.auto,
    this.cameraQuality = CameraQuality.balanced,
    this.cameraOnJoin = false,
    this.mirrorSelfView = true,
    this.pushToTalkEnabled = false,
    this.pushToTalkKey = kDefaultPushToTalkKey,
    this.voiceActivitySensitivity = 100.0,
    this.inputThresholdDb = kDefaultInputThresholdDb,
    this.inputThresholdAuto = false,
    this.evenOutLoudSounds = true,
    this.screenShareIncludeAudio = false,
    this.pauseVideoWhenMinimised = true,
    this.micFallbackEnabled = true,
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

  /// Which style plays while you are alone.
  final LoungeTrack holdMusicTrack;

  /// How loud that music is, 0 to 1.
  final double holdMusicVolume;
  final ScreenShareQuality screenShareQuality;

  /// How sharp the video you watch is; see [ReceiveVideoQuality].
  final ReceiveVideoQuality receiveVideoQuality;

  /// How sharp your camera publishes; see [CameraQuality].
  final CameraQuality cameraQuality;

  /// Whether a fresh session's first join should ask for a camera; see
  /// [VoiceSettingsController.setCameraOnJoin].
  final bool cameraOnJoin;

  /// Whether your own camera preview is drawn mirrored; others never see it so.
  final bool mirrorSelfView;

  /// Whether holding [pushToTalkKey] unmutes for the hold and re-mutes on
  /// release; see `push_to_talk_listener.dart`. Off by default and desktop
  /// only - keyboard focus semantics make "held" meaningless on touch.
  final bool pushToTalkEnabled;

  /// Any single key the person picked. Held while typing (a screen-reader user
  /// or anyone drafting a message may well type it), so what actually keeps
  /// this safe is the composer-focus guard, not this being a rare key.
  final LogicalKeyboardKey pushToTalkKey;

  /// 0-100, how readily the speaking indicator lights: 100 (the default)
  /// matches every call's behaviour before this setting existed, lower
  /// values require a louder reported level on top of it; see
  /// `passesActivationThreshold` in the rtc package for the exact floor and
  /// why it can only narrow the SFU's own decision, never invent one.
  final double voiceActivitySensitivity;

  /// Microphone audio quieter than this, in dBFS, is not sent; see
  /// `InputGateMonitor` in the rtc package.
  final double inputThresholdDb;

  /// Whether the threshold follows the room's noise floor instead of
  /// [inputThresholdDb].
  final bool inputThresholdAuto;

  /// Whether shouts are softened and sudden peaks capped before sending.
  final bool evenOutLoudSounds;

  /// Whether a screen share should try to publish this device's own audio
  /// alongside it. Defaults off: a stray notification chime becomes
  /// everyone's problem, where a share's video is at least something the
  /// sharer chose to show. The toggle offering this is shown only where
  /// `VoiceController.supportsScreenShareAudio` is true, and
  /// `VoiceController.setScreenShare` re-checks that same capability before
  /// honouring this value.
  final bool screenShareIncludeAudio;

  /// Whether incoming video stops while the desktop window is visible but not focused.
  final bool pauseVideoWhenMinimised;
  final bool micFallbackEnabled;

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
    LoungeTrack? holdMusicTrack,
    double? holdMusicVolume,
    ScreenShareQuality? screenShareQuality,
    ReceiveVideoQuality? receiveVideoQuality,
    CameraQuality? cameraQuality,
    bool? cameraOnJoin,
    bool? mirrorSelfView,
    bool? pushToTalkEnabled,
    LogicalKeyboardKey? pushToTalkKey,
    double? voiceActivitySensitivity,
    double? inputThresholdDb,
    bool? inputThresholdAuto,
    bool? evenOutLoudSounds,
    bool? screenShareIncludeAudio,
    bool? pauseVideoWhenMinimised,
    bool? micFallbackEnabled,
    String? audioInputDeviceId,
    bool clearAudioInputDeviceId = false,
    String? audioOutputDeviceId,
    bool clearAudioOutputDeviceId = false,
  }) => VoiceSettingsState(
    joinLeaveSoundsEnabled:
        joinLeaveSoundsEnabled ?? this.joinLeaveSoundsEnabled,
    callRingSoundEnabled: callRingSoundEnabled ?? this.callRingSoundEnabled,
    holdMusicEnabled: holdMusicEnabled ?? this.holdMusicEnabled,
    holdMusicTrack: holdMusicTrack ?? this.holdMusicTrack,
    holdMusicVolume: holdMusicVolume ?? this.holdMusicVolume,
    screenShareQuality: screenShareQuality ?? this.screenShareQuality,
    receiveVideoQuality: receiveVideoQuality ?? this.receiveVideoQuality,
    cameraQuality: cameraQuality ?? this.cameraQuality,
    cameraOnJoin: cameraOnJoin ?? this.cameraOnJoin,
    mirrorSelfView: mirrorSelfView ?? this.mirrorSelfView,
    pushToTalkEnabled: pushToTalkEnabled ?? this.pushToTalkEnabled,
    pushToTalkKey: pushToTalkKey ?? this.pushToTalkKey,
    voiceActivitySensitivity:
        voiceActivitySensitivity ?? this.voiceActivitySensitivity,
    inputThresholdDb: inputThresholdDb ?? this.inputThresholdDb,
    inputThresholdAuto: inputThresholdAuto ?? this.inputThresholdAuto,
    evenOutLoudSounds: evenOutLoudSounds ?? this.evenOutLoudSounds,
    screenShareIncludeAudio:
        screenShareIncludeAudio ?? this.screenShareIncludeAudio,
    pauseVideoWhenMinimised:
        pauseVideoWhenMinimised ?? this.pauseVideoWhenMinimised,
    micFallbackEnabled: micFallbackEnabled ?? this.micFallbackEnabled,
    audioInputDeviceId: clearAudioInputDeviceId
        ? null
        : (audioInputDeviceId ?? this.audioInputDeviceId),
    audioOutputDeviceId: clearAudioOutputDeviceId
        ? null
        : (audioOutputDeviceId ?? this.audioOutputDeviceId),
  );
}
