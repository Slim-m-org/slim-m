// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The raw sample's capture: the preview's loopback with libwebrtc's own
/// processing off, read through the fork's tap at the head of the chain.
library;

import 'dart:typed_data';

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
import 'input_gate.dart' show supportsInputGate;
import 'mic_preview_loopback.dart';
import 'mic_sample.dart';

/// Only the fork's desktop chain (Linux and Windows) has the tap.
bool get supportsMicSample => supportsInputGate;

class NativeMicSampleSource implements MicSampleSource {
  NativeMicSampleSource(AudioDeviceSwitching switching)
      : _loopback = LoopbackMicSource(switching, raw: true);

  final LoopbackMicSource _loopback;

  @override
  Future<void> open(String? deviceId) => _loopback.open(deviceId);

  @override
  Future<void> start(int seconds) => rtc.WebRTC.invokeMethod<void, Object?>(
        'startMicSample',
        <String, dynamic>{'seconds': seconds},
      );

  @override
  Future<MicSampleChunk> take() async {
    final raw =
        await rtc.WebRTC.invokeMethod<Object?, Object?>('takeMicSample');
    if (raw is! Map) return MicSampleChunk(pcm: Uint8List(0));
    final pcm = raw['pcm'];
    return MicSampleChunk(
      pcm: pcm is Uint8List ? pcm : Uint8List(0),
      rateHz: (raw['rateHz'] as num?)?.toInt() ?? kMicSampleRateHz,
      skippedFrames: (raw['skippedFrames'] as num?)?.toInt() ?? 0,
      full: raw['full'] == true,
    );
  }

  @override
  Future<void> stop() =>
      rtc.WebRTC.invokeMethod<void, Object?>('stopMicSample');

  @override
  Future<void> close() => _loopback.close();
}

/// A raw sample over the real microphone, on this host's own device list.
MicSampleRecorder systemMicSampleRecorder() => MicSampleRecorder(
      source: NativeMicSampleSource(
        AudioDeviceSwitching(HardwareAudioDevices()),
      ),
    );
