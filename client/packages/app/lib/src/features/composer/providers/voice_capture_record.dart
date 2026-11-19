// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone through the `record` package.
///
/// 16 kHz mono WAV on every platform, because every client plays voice
/// messages through audioplayers, which cannot decode Ogg on Windows or iPhone.
/// On Linux the plugin writes files only through ffmpeg, so there the WAV is
/// built here from its raw samples, which need parecord alone.
library;

import 'dart:io' show File;
import 'dart:typed_data' show BytesBuilder;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart' show AudioDevice, pulseDevicePrefix;

import 'voice_recording.dart';

const _sampleRate = 16000;
const _channels = 1;

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

bool get _streamsPcm =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

/// [pcm] as a 16-bit PCM WAV file, cut to whole frames.
Uint8List _wav(Uint8List pcm) {
  const frame = 2 * _channels;
  final length = pcm.length - pcm.length % frame;
  final out = Uint8List(44 + length);
  final view = ByteData.sublistView(out);
  void tag(int at, String text) => out.setRange(at, at + 4, text.codeUnits);
  tag(0, 'RIFF');
  view.setUint32(4, 36 + length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  view
    ..setUint32(16, 16, Endian.little)
    ..setUint16(20, 1, Endian.little)
    ..setUint16(22, _channels, Endian.little)
    ..setUint32(24, _sampleRate, Endian.little)
    ..setUint32(28, _sampleRate * frame, Endian.little)
    ..setUint16(32, frame, Endian.little)
    ..setUint16(34, 16, Endian.little);
  tag(36, 'data');
  view.setUint32(40, length, Endian.little);
  out.setRange(44, 44 + length, pcm);
  return out;
}

class RecordVoiceCapture implements VoiceCaptureBackend {
  RecordVoiceCapture({this.chosenInput = _systemDefault});

  /// The microphone picked in Voice settings, null for the system default.
  final Future<AudioDevice?> Function() chosenInput;

  static Future<AudioDevice?> _systemDefault() async => null;

  AudioRecorder? _created;
  AudioRecorder get _recorder => _created ??= AudioRecorder();

  /// The raw samples so far, on Linux only.
  BytesBuilder? _pcm;

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    final device = await _device();
    if (_streamsPcm) {
      final samples = await _recorder.startStream(
        _config(AudioEncoder.pcm16bits, device),
      );
      final pcm = _pcm = BytesBuilder(copy: false);
      samples.listen(
        pcm.add,
        onError: (Object error, StackTrace stack) => AppLog.swallowed(
          LogTag.voice,
          'The microphone stream reported an error',
          error,
          stack,
        ),
      );
      return true;
    }
    await _recorder.start(
      _config(AudioEncoder.wav, device),
      path: await _newPath(),
    );
    return true;
  }

  RecordConfig _config(AudioEncoder encoder, InputDevice? device) =>
      RecordConfig(
        encoder: encoder,
        sampleRate: _sampleRate,
        numChannels: _channels,
        device: device,
      );

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
    if (_pcm case final pcm?) {
      _pcm = null;
      return VoiceCapture(
        bytes: _wav(pcm.takeBytes()),
        filename: 'voice-message.wav',
      );
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
    _pcm = null;
    await _created?.cancel();
    await _created?.dispose();
  }
}
