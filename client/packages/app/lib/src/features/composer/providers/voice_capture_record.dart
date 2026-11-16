// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone through the `record` package.
///
/// 16 kHz mono WAV on every platform, because every client plays voice
/// messages through audioplayers, which cannot decode Ogg on Windows or iPhone.
library;

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart' show AudioDevice, pulseDevicePrefix;

import 'voice_recording.dart';

const _sampleRate = 16000;

/// Quietest level shown, in dBFS; anything below reads as silence.
const _floorDb = 60.0;

/// [chosen] in the plugin's own list, matched by id and then by name; null
/// (the system default) when it is not plugged in.
InputDevice? _matchInput(AudioDevice chosen, List<InputDevice> devices) {
  final id = chosen.id.startsWith(pulseDevicePrefix)
      ? chosen.id.substring(pulseDevicePrefix.length)
      : chosen.id;
  return devices.where((d) => d.id == id).firstOrNull ??
      devices
          .where((d) => chosen.label.isNotEmpty && d.label == chosen.label)
          .firstOrNull;
}

class RecordVoiceCapture implements VoiceCaptureBackend {
  RecordVoiceCapture({this.chosenInput = _systemDefault});

  /// The microphone picked in Voice settings, null for the system default.
  final Future<AudioDevice?> Function() chosenInput;

  static Future<AudioDevice?> _systemDefault() async => null;

  AudioRecorder? _created;
  AudioRecorder get _recorder => _created ??= AudioRecorder();

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    await _recorder.start(
      RecordConfig(
        encoder: AudioEncoder.wav,
        sampleRate: _sampleRate,
        numChannels: 1,
        device: await _device(),
      ),
      path: await _newPath(),
    );
    return true;
  }

  Future<InputDevice?> _device() async {
    try {
      final chosen = await chosenInput();
      if (chosen == null) return null;
      return _matchInput(chosen, await _recorder.listInputDevices());
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'Could not find the chosen microphone; recording from the default',
        error,
        stack,
      );
      return null;
    }
  }

  Future<String> _newPath() async {
    if (kIsWeb) return '';
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return p.join(dir.path, 'voice-message-$stamp.wav');
  }

  @override
  Future<double> level() async {
    final amplitude = await _recorder.getAmplitude();
    return ((amplitude.current + _floorDb) / _floorDb).clamp(0.0, 1.0);
  }

  @override
  Future<VoiceCapture?> stop() async {
    final String? path;
    try {
      path = await _recorder.stop();
    } finally {
      await _recorder.dispose();
    }
    if (path == null || path.isEmpty) return null;
    final bytes = await _read(path);
    return VoiceCapture(bytes: bytes, filename: 'voice-message.wav');
  }

  Future<Uint8List> _read(String path) async {
    if (kIsWeb) return (await http.get(Uri.parse(path))).bodyBytes;
    final file = File(path);
    final bytes = await file.readAsBytes();
    await file.delete();
    return bytes;
  }

  @override
  Future<void> cancel() async {
    await _created?.cancel();
    await _created?.dispose();
  }
}
