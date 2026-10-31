// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import 'noise_suppression.dart';
import 'voice_processing.dart';
import 'voice_settings_controller.dart';
import 'voice_state.dart';
import 'voice_state_access.dart';

/// How often a call asks for the Space's noise suppression default again.
const kSpaceNoiseSuppressionRecheck = Duration(minutes: 1);

/// Shortened by tests; production leaves it at [kSpaceNoiseSuppressionRecheck].
@visibleForTesting
Duration spaceNoiseSuppressionRecheck = kSpaceNoiseSuppressionRecheck;

/// The microphone, noise suppression, input gate and video quality choices
/// the controller applies to its session, before a call and live in one.
class VoiceInputSettings {
  VoiceInputSettings(this._session, this._ref, this._access);

  final VoiceSession _session;
  final Ref _ref;
  final VoiceStateAccess _access;

  VoiceState get _current => _access.state;

  /// the controller's restoreCameraPreference's own shape, for the
  /// session's speaking threshold: it already exists at construction, so
  /// this only has to run once, before any call.
  Future<void> restoreVoiceActivitySensitivity() async {
    _session.setSpeakingSensitivity(
      await loadVoiceActivitySensitivity(_ref) / 100,
    );
  }

  /// Live, in-call equivalent of [restoreVoiceActivitySensitivity].
  void setVoiceActivitySensitivity(double sensitivityPercent) {
    _session.setSpeakingSensitivity(sensitivityPercent / 100);
  }

  double _inputThresholdDb = kDefaultInputThresholdDb;

  bool get supportsInputGate => _session.supportsInputGate;

  Stream<InputGateReading> get inputGateReadings => _session.inputGateReadings;

  /// Seeds the input gate's threshold before any call.
  Future<void> restoreInputThreshold() async {
    setInputThreshold(await loadInputThreshold(_ref));
  }

  /// Live, in-call equivalent of [restoreInputThreshold].
  void setInputThreshold(double db) {
    _inputThresholdDb = db;
    _applyInputGate();
  }

  /// The threshold the gate uses now, which automatic mode keeps moving.
  double get inputThresholdDb => _session.inputThresholdDb;

  /// Where automatic mode has put the threshold, as it moves.
  Stream<double> get autoInputThresholds => _session.autoInputThresholds;

  /// Whether the threshold follows the noise floor instead of the slider.
  void setInputThresholdAuto(bool enabled) =>
      _session.setAutoInputThreshold(enabled);

  /// Seeds automatic sensitivity before any call.
  Future<void> restoreInputThresholdAuto() async {
    setInputThresholdAuto(await loadInputThresholdAuto(_ref));
  }

  /// Seeds the microphone's compressor and limiter before any call.
  Future<void> restoreEvenOutLoudSounds() async {
    setEvenOutLoudSounds(await loadEvenOutLoudSounds(_ref));
  }

  /// Live, in-call equivalent of [restoreEvenOutLoudSounds].
  void setEvenOutLoudSounds(bool enabled) =>
      _session.setEvenOutLoudSounds(enabled);

  /// Seeds the filters before any call.
  Future<void> restoreVoiceProcessing() async {
    await setVoiceProcessing(await loadVoiceProcessing(_ref));
  }

  /// Reopens a live microphone with [processing], which libwebrtc fixes at open.
  Future<void> setVoiceProcessing(VoiceProcessing processing) =>
      _session.setVoiceProcessing(processing);

  NoiseSuppressionChoice _noiseSuppression =
      NoiseSuppressionChoice.spaceDefault;
  bool _spaceStrongNoiseSuppression = false;

  /// Seeds the noise suppression choice and the Space's default before any
  /// call.
  Future<void> restoreNoiseSuppression() async {
    _noiseSuppression = await loadNoiseSuppressionChoice(_ref);
    await refreshSpaceNoiseSuppression();
  }

  /// Live, in-call equivalent of [restoreNoiseSuppression].
  void setNoiseSuppression(NoiseSuppressionChoice choice) {
    _noiseSuppression = choice;
    _applyNoiseSuppression();
  }

  /// Rereads the Space's default, which an admin may have changed since
  /// launch. A failed read keeps the last known value instead of Standard.
  Future<void> refreshSpaceNoiseSuppression() async {
    final fetched = await fetchSpaceStrongNoiseSuppression(_ref);
    if (fetched == null || fetched == _spaceStrongNoiseSuppression) return;
    _spaceStrongNoiseSuppression = fetched;
    _applyNoiseSuppression();
  }

  Timer? _spaceDefaultTimer;

  /// No event announces the Space default, so a call asks again periodically.
  void watchSpaceNoiseSuppression() {
    _spaceDefaultTimer?.cancel();
    unawaited(refreshSpaceNoiseSuppression());
    _spaceDefaultTimer = Timer.periodic(
      spaceNoiseSuppressionRecheck,
      (_) => unawaited(refreshSpaceNoiseSuppression()),
    );
  }

  void stopWatchingSpaceNoiseSuppression() {
    _spaceDefaultTimer?.cancel();
    _spaceDefaultTimer = null;
  }

  void _applyNoiseSuppression() => _session.setStrongNoiseSuppression(
    _noiseSuppression.isStrong(spaceStrong: _spaceStrongNoiseSuppression),
    strongest: _noiseSuppression.isStrongest(
      supported: _ref.read(strongestSupportedProvider),
    ),
  );

  /// Push-to-talk decides when you are heard, so the gate only meters then.
  void _applyInputGate() => _session.setInputGate(
    enabled: !_pushToTalkEnabled,
    thresholdDb: _inputThresholdDb,
  );

  /// A phone that is not on screen gives a muted microphone back at once.
  void setAppBackgrounded(bool backgrounded) =>
      _session.setAppBackgrounded(backgrounded);

  /// Seeds the session's video quality choices at launch, for the same
  /// reason as [restoreVoiceActivitySensitivity].
  Future<void> restoreVideoQuality() async {
    final (receive, camera) = await loadVideoQualityPreferences(_ref);
    setReceiveVideoQuality(receive);
    setCameraQuality(camera);
  }

  /// Caps how sharp the video you watch is, live in a call.
  void setReceiveVideoQuality(ReceiveVideoQuality quality) =>
      _session.setReceiveVideoQuality(quality);

  /// Sets how sharp your camera publishes; [restartCamera] applies it to a live one.
  void setCameraQuality(CameraQuality quality) =>
      _session.setCameraQuality(quality);

  /// Whether push-to-talk is on, kept on the controller so
  /// the controller's join can start the microphone closed without reaching
  /// into another provider on the hot path. Voice Settings pushes changes
  /// through [setPushToTalkPreference], the same way it feeds
  /// the controller's setCameraPreference and [setVoiceActivitySensitivity].
  bool _pushToTalkEnabled = false;

  bool get pushToTalkEnabled => _pushToTalkEnabled;

  /// Records whether push-to-talk is on, and applies the change to a call
  /// already in progress: enabling closes the mic so it is push-only from
  /// now, disabling reopens it, since the person is no longer holding a key
  /// to be heard on. Outside a call it only sets the flag
  /// the controller's join reads.
  void setPushToTalkPreference(bool enabled) {
    _pushToTalkEnabled = enabled;
    unawaited(_session.setKeepMicReady(enabled));
    _applyInputGate();
    if (_current.state != VoiceSessionState.connected) return;
    unawaited(setPushToTalkHeld(enabled ? false : true));
  }

  /// Seeds [setPushToTalkPreference] at launch,
  /// the controller's restoreCameraPreference's own shape and for the same
  /// reason: the controller's join must know before the first call, not only
  /// once Voice Settings has been opened this session.
  Future<void> restorePushToTalkPreference() async {
    setPushToTalkPreference(await loadPushToTalkEnabled(_ref));
  }

  /// Push-to-talk's own entry point: sets the microphone explicitly to
  /// [heldOpen] rather than flipping it, since a repeated or out-of-order
  /// key event must never invert this. A no-op outside a live call, so a
  /// key held before joining or after leaving cannot corrupt
  /// [VoiceState.microphoneEnabled]'s other duty as the pre-join preference.
  Future<void> setPushToTalkHeld(bool heldOpen) async {
    if (_current.state != VoiceSessionState.connected) return;
    final got = await _session.setMicrophoneEnabled(heldOpen);
    _access.state = _current.copyWith(
      microphoneEnabled: got ? heldOpen : _current.microphoneEnabled,
    );
  }
}
