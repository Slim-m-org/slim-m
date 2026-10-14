// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'voice_controller.dart';

/// Push-to-talk and voice-activity sensitivity, split out for
/// [VoiceController]'s own 500-line hard ceiling. A mixin rather than an
/// extension: once mixed in it is a real member of the class hierarchy, so
/// [state] (`StateNotifier`'s own accessor, `@protected`/`@visibleForTesting`)
/// is reachable the way it would be from any other method declared on
/// [VoiceController] itself - an extension is never that, however private
/// its name or however it reaches this file.
mixin VoiceControllerInputMixin on StateNotifier<VoiceState> {
  /// Bridges to [VoiceController]'s own private fields; declared abstract
  /// here because a mixin's `on` clause, not shared-library privacy, is what
  /// bounds which members it can reach through an implicit receiver.
  VoiceSession get _inputSession;
  Ref get _inputRef;

  /// [VoiceController.restoreCameraPreference]'s own shape, for the
  /// session's speaking threshold: it already exists at construction, so
  /// this only has to run once, before any call.
  Future<void> restoreVoiceActivitySensitivity() async {
    _inputSession.setSpeakingSensitivity(
      await loadVoiceActivitySensitivity(_inputRef) / 100,
    );
  }

  /// Live, in-call equivalent of [restoreVoiceActivitySensitivity].
  void setVoiceActivitySensitivity(double sensitivityPercent) {
    _inputSession.setSpeakingSensitivity(sensitivityPercent / 100);
  }

  double _inputThresholdDb = kDefaultInputThresholdDb;

  bool get supportsInputGate => _inputSession.supportsInputGate;

  Stream<InputGateReading> get inputGateReadings =>
      _inputSession.inputGateReadings;

  /// Seeds the input gate's threshold before any call.
  Future<void> restoreInputThreshold() async {
    setInputThreshold(await loadInputThreshold(_inputRef));
  }

  /// Live, in-call equivalent of [restoreInputThreshold].
  void setInputThreshold(double db) {
    _inputThresholdDb = db;
    _applyInputGate();
  }

  /// Push-to-talk decides when you are heard, so the gate only meters then.
  void _applyInputGate() => _inputSession.setInputGate(
    enabled: !_pushToTalkEnabled,
    thresholdDb: _inputThresholdDb,
  );

  /// Seeds the session's video quality choices at launch, for the same
  /// reason as [restoreVoiceActivitySensitivity].
  Future<void> restoreVideoQuality() async {
    final (receive, camera) = await loadVideoQualityPreferences(_inputRef);
    setReceiveVideoQuality(receive);
    setCameraQuality(camera);
  }

  /// Caps how sharp the video you watch is, live in a call.
  void setReceiveVideoQuality(ReceiveVideoQuality quality) =>
      _inputSession.setReceiveVideoQuality(quality);

  /// Sets how sharp your camera publishes, from its next start.
  void setCameraQuality(CameraQuality quality) =>
      _inputSession.setCameraQuality(quality);

  /// Whether push-to-talk is on, kept on the controller so
  /// [VoiceController.join] can start the microphone closed without reaching
  /// into another provider on the hot path. Voice Settings pushes changes
  /// through [setPushToTalkPreference], the same way it feeds
  /// [VoiceController.setCameraPreference] and [setVoiceActivitySensitivity].
  bool _pushToTalkEnabled = false;

  /// Records whether push-to-talk is on, and applies the change to a call
  /// already in progress: enabling closes the mic so it is push-only from
  /// now, disabling reopens it, since the person is no longer holding a key
  /// to be heard on. Outside a call it only sets the flag
  /// [VoiceController.join] reads.
  void setPushToTalkPreference(bool enabled) {
    _pushToTalkEnabled = enabled;
    _applyInputGate();
    if (state.state != VoiceSessionState.connected) return;
    unawaited(setPushToTalkHeld(enabled ? false : true));
  }

  /// Seeds [setPushToTalkPreference] at launch,
  /// [VoiceController.restoreCameraPreference]'s own shape and for the same
  /// reason: [VoiceController.join] must know before the first call, not only
  /// once Voice Settings has been opened this session.
  Future<void> restorePushToTalkPreference() async {
    setPushToTalkPreference(await loadPushToTalkEnabled(_inputRef));
  }

  /// Push-to-talk's own entry point: sets the microphone explicitly to
  /// [heldOpen] rather than flipping it, since a repeated or out-of-order
  /// key event must never invert this. A no-op outside a live call, so a
  /// key held before joining or after leaving cannot corrupt
  /// [VoiceState.microphoneEnabled]'s other duty as the pre-join preference.
  Future<void> setPushToTalkHeld(bool heldOpen) async {
    if (state.state != VoiceSessionState.connected) return;
    final got = await _inputSession.setMicrophoneEnabled(heldOpen);
    state = state.copyWith(
      microphoneEnabled: got ? heldOpen : state.microphoneEnabled,
    );
  }
}
