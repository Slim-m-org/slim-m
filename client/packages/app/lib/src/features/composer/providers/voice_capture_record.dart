// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone through the `record` package.
///
/// Opus in Ogg at 32 kbit/s where the platform writes it (Android and Linux);
/// 16 kHz mono WAV elsewhere, because Apple writes Opus only in a CAF file
/// nothing else plays and Windows and the web have no Opus encoder.
library;

import 'dart:io' show File;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'voice_recording.dart';

const _sampleRate = 16000;
const _opusBitRate = 32000;

/// The Opus-capable platforms; the rest record WAV.
bool prefersOpus(TargetPlatform platform, {required bool isWeb}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.linux);

/// Quietest level shown, in dBFS; anything below reads as silence.
const _floorDb = 60.0;

class RecordVoiceCapture implements VoiceCaptureBackend {
  AudioRecorder? _created;
  AudioRecorder get _recorder => _created ??= AudioRecorder();

  String? _extension;

  @override
  Future<bool> start() async {
    if (!await _recorder.hasPermission()) return false;
    final opus =
        prefersOpus(defaultTargetPlatform, isWeb: kIsWeb) &&
        await _recorder.isEncoderSupported(AudioEncoder.opus);
    if (opus) {
      // Linux encodes with ffmpeg, which may not be installed.
      try {
        await _begin(AudioEncoder.opus, 'ogg');
        return true;
      } on Object catch (error, stack) {
        AppLog.swallowed(
          LogTag.voice,
          'Opus recording failed, recording WAV instead',
          error,
          stack,
        );
        await _recorder.cancel();
      }
    }
    await _begin(AudioEncoder.wav, 'wav');
    return true;
  }

  Future<void> _begin(AudioEncoder encoder, String extension) async {
    _extension = extension;
    await _recorder.start(
      RecordConfig(
        encoder: encoder,
        bitRate: _opusBitRate,
        sampleRate: _sampleRate,
        numChannels: 1,
      ),
      path: await _newPath(extension),
    );
  }

  Future<String> _newPath(String extension) async {
    if (kIsWeb) return '';
    final dir = await getTemporaryDirectory();
    final stamp = DateTime.now().microsecondsSinceEpoch;
    return p.join(dir.path, 'voice-message-$stamp.$extension');
  }

  @override
  Future<double> level() async {
    final amplitude = await _recorder.getAmplitude();
    return ((amplitude.current + _floorDb) / _floorDb).clamp(0.0, 1.0);
  }

  @override
  Future<VoiceCapture?> stop() async {
    final path = await _recorder.stop();
    await _recorder.dispose();
    if (path == null || path.isEmpty) return null;
    final bytes = await _read(path);
    return VoiceCapture(
      bytes: bytes,
      filename: 'voice-message.${_extension ?? 'wav'}',
    );
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
