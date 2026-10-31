// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/providers.dart';
import 'voice_deafen_publish.dart';
import 'voice_settings_controller.dart';
import 'voice_state_access.dart';

/// Microphone and speaker device selection, plus the microphone's own health
/// and fallback notices.
class VoiceAudioDevices {
  VoiceAudioDevices(this._session, this._ref, this._access);

  final VoiceSession _session;
  final Ref _ref;
  final VoiceStateAccess _access;

  /// Whether picking a specific microphone changes anything live; see
  /// [VoiceSession.supportsAudioInputSelection].
  bool get supportsAudioInputSelection => _session.supportsAudioInputSelection;

  /// Whether picking a specific speaker changes anything live; see
  /// [VoiceSession.supportsAudioOutputSelection].
  bool get supportsAudioOutputSelection =>
      _session.supportsAudioOutputSelection;

  /// The speaker in use, null for the system default; see
  /// [VoiceSession.audioOutputInUse].
  String? get audioOutputInUse => _session.audioOutputInUse;

  /// Fires when the platform's own device list changes; see
  /// [VoiceSession.audioDeviceChanges].
  Stream<void> get audioDeviceChanges => _session.audioDeviceChanges;

  /// The microphones available to pick from.
  Future<List<AudioDevice>> audioInputDevices() => _session.audioInputDevices();

  /// The speakers available to pick from.
  Future<List<AudioDevice>> audioOutputDevices() =>
      _session.audioOutputDevices();

  /// Seeds the persisted microphone/speaker choice before any call exists;
  /// The shape of the controller's restoreCameraPreference, for audio. Only
  /// the id survives a restart (see `voice_settings_controller.dart`), so a
  /// bare label stands in here - nothing reads it until a real [AudioDevice]
  /// from a fresh enumeration replaces it.
  Future<void> restoreAudioDevicePreferences() async {
    final (inputId, outputId) = await loadAudioDevicePreferences(_ref);
    await _session.selectAudioInputDevice(_asPreference(inputId));
    await _session.selectAudioOutputDevice(_asPreference(outputId));
  }

  AudioDevice? _asPreference(String? id) =>
      id == null ? null : AudioDevice(id: id, label: id);

  /// Seeds the fallback switch before any call; see [VoiceSession.setMicFallbackEnabled].
  Future<void> restoreMicFallback() async {
    _session.setMicFallbackEnabled(await loadMicFallbackEnabled(_ref));
  }

  void setMicFallbackEnabled(bool enabled) =>
      _session.setMicFallbackEnabled(enabled);

  /// The microphone the call switched to on its own; null once dismissed.
  String? get micFallbackNotice => _session.micFallbackNotice;
  Stream<String?> get micFallbackNotices => _session.micFallbackNotices;
  void dismissMicFallbackNotice() => _session.dismissMicFallbackNotice();

  /// Switches the microphone to [device] (null for the system default),
  /// live or at the next join; see [VoiceSession.selectAudioInputDevice].
  Future<bool> selectAudioInputDevice(AudioDevice? device) async {
    final ok = await _session.selectAudioInputDevice(device);
    _access.state = _access.state.copyWith(
      error: ok ? null : 'Could not switch to that microphone.',
      clearError: ok,
    );
    return ok;
  }

  /// [selectAudioInputDevice]'s counterpart for output.
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async {
    final ok = await _session.selectAudioOutputDevice(device);
    _access.state = _access.state.copyWith(
      error: ok ? null : 'Could not switch to that speaker.',
      clearError: ok,
    );
    return ok;
  }

  /// Whether the microphone is healthy, coming back, or given up on; see
  /// [VoiceSession.micStatus].
  MicStatus get micStatus => _session.micStatus;
  Stream<MicStatus> get micStatuses => _session.micStatuses;

  /// Why the microphone last failed to open; see [VoiceSession.micFailure].
  MicFailureReason? get micFailure => _session.micFailure;
  Stream<MicFailureReason?> get micFailures => _session.micFailures;

  /// Tells the call this client deafened or undeafened itself.
  Future<void> publishDeafenedState(bool deafened) => publishDeafened(
    _ref.read(apiProvider),
    _access.state.channelId,
    deafened: deafened,
    onError: (e) => api.AppLog.swallowed(
      api.LogTag.voice,
      'Could not tell the call this client is deafened',
      e,
      null,
    ),
  );

  /// The mic button's tap-to-retry once recovery gave up: reopens the capture
  /// even when the device is unchanged; see [VoiceSession.resetMicrophone].
  Future<bool> resetMicrophone() async {
    final ok = await _session.resetMicrophone();
    if (!ok) {
      _access.state = _access.state.copyWith(
        error: 'Could not reset the microphone.',
      );
    }
    return ok;
  }
}
