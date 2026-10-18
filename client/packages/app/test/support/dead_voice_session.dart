// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A [VoiceSession] that connects to nothing, for tests that drive
/// [VoiceController] state directly.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_rtc/rtc.dart';

import 'video_quality_recorder.dart';

class DeadVoiceSession with VideoQualityRecorder implements VoiceSession {
  @override
  Stream<VoiceSessionState> get states => const Stream.empty();
  @override
  Stream<List<VoiceParticipant>> get participantChanges => const Stream.empty();
  @override
  List<VoiceParticipant> get participants => const [];
  @override
  VoiceSessionState get state => VoiceSessionState.idle;
  @override
  Object? get lastError => null;
  @override
  VoiceDisconnect? get lastDisconnect => null;
  @override
  bool deafened = false;
  @override
  bool get supportsParticipantVolume => false;

  @override
  double screenVolumeFor(String identity) => 1.0;

  @override
  Future<void> setScreenVolumeFor(String identity, double volume) async {}

  @override
  bool isScreenAudioMuted(String identity) => false;

  @override
  Future<void> setScreenAudioMuted(String identity, bool muted) async {}

  @override
  bool hasScreenAudio(String identity) => false;

  @override
  Object? volumeFailureFor(String identity, {bool screen = false}) => null;
  @override
  bool get supportsScreenShareAudio => false;
  @override
  double volumeFor(String identity) => 1.0;
  @override
  Future<void> setVolumeFor(String identity, double volume) async {}
  @override
  bool get screenShareNeedsSource => false;
  @override
  bool get screenShareSourcePickerUseful => false;
  @override
  Future<List<ScreenShareSource>> screenShareSources() async => const [];
  @override
  bool isLocallyMuted(String identity) => false;
  @override
  Future<void> setLocallyMuted(String identity, bool muted) async {}
  @override
  Widget screenShareViewFor(String identity) => throw UnimplementedError();
  @override
  Widget cameraViewFor(String identity) => throw UnimplementedError();
  @override
  void setVideoInterest(Set<String>? tileKeys) {}

  @override
  void setVideoBlocked(Set<String> tileKeys) {}
  @override
  bool get supportsInputGate => false;

  @override
  Stream<InputGateReading> get inputGateReadings => const Stream.empty();

  @override
  void setInputGate({required bool enabled, required double thresholdDb}) {}

  @override
  Stream<double> get autoInputThresholds => const Stream.empty();

  @override
  double get inputThresholdDb => -50;

  @override
  void setLevelDisplayed(bool displayed) {}

  @override
  void setAutoInputThreshold(bool enabled) {}

  @override
  void setSpeakingSensitivity(double sensitivity) {}
  @override
  bool get canFlipCamera => false;
  @override
  bool get cameraNeedsSelection => false;
  @override
  Future<List<CameraDevice>> cameraDevices() async => const [];
  @override
  Future<bool> flipCamera() async => false;
  @override
  Future<bool> selectCameraDevice(CameraDevice device) async => false;

  @override
  bool get supportsAudioInputSelection => false;

  @override
  bool get supportsAudioOutputSelection => false;

  @override
  Stream<void> get audioDeviceChanges => const Stream.empty();

  @override
  Future<List<AudioDevice>> audioInputDevices() async => const [];

  @override
  Future<List<AudioDevice>> audioOutputDevices() async => const [];

  @override
  Future<bool> selectAudioInputDevice(AudioDevice? device) async => false;

  @override
  Future<bool> selectAudioOutputDevice(AudioDevice? device) async => false;
  @override
  Future<void> join({
    required String url,
    required String token,
    bool microphoneEnabled = true,
    bool cameraEnabled = false,
  }) async {}
  @override
  Future<void> leave() async {}
  @override
  Future<bool> setMicrophoneEnabled(bool enabled) async => true;
  @override
  Future<bool> setCameraEnabled(bool enabled) async => true;
  @override
  Future<ScreenShareOutcome> setScreenShareEnabled(
    bool enabled, {
    ScreenShareQuality quality = ScreenShareQuality.standard,
    String? sourceId,
    bool includeAudio = false,
    int? maxHeight,
  }) async => ScreenShareOutcome.stopped;
  @override
  Future<bool> setDeafened(bool value) async => true;
  @override
  Future<void> dispose() async {}
}
