// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A raw microphone sample for the noise corpus: the capture as it reaches the
/// chain, before suppression, gate or dynamics, kept on this device as a WAV.
library;

import 'dart:async';
import 'dart:typed_data';

/// How long a sample runs.
const int kMicSampleSeconds = 30;

/// The rate the native tap delivers, mono, 16-bit.
const int kMicSampleRateHz = 48000;

/// What the native tap has kept since the last [MicSampleSource.take].
class MicSampleChunk {
  const MicSampleChunk({
    required this.pcm,
    this.rateHz = kMicSampleRateHz,
    this.skippedFrames = 0,
    this.full = false,
  });

  /// Little-endian 16-bit mono samples.
  final Uint8List pcm;
  final int rateHz;

  /// Frames the tap could not bring to 48 kHz.
  final int skippedFrames;

  /// The tap has kept as much as it was asked for.
  final bool full;
}

/// One raw capture the recorder owns.
abstract interface class MicSampleSource {
  /// Opens the microphone with libwebrtc's own processing off.
  Future<void> open(String? deviceId);

  /// Starts keeping [seconds] of what the chain receives.
  Future<void> start(int seconds);
  Future<MicSampleChunk> take();
  Future<void> stop();
  Future<void> close();
}

class MicSampleException implements Exception {
  const MicSampleException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// A 44-byte RIFF header and then the samples, as a mono 16-bit WAV.
Uint8List wavFromPcm16(Uint8List pcm, {int rateHz = kMicSampleRateHz}) {
  final out = ByteData(44 + pcm.length);
  void tag(int at, String text) {
    for (var i = 0; i < text.length; i++) {
      out.setUint8(at + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  out.setUint32(4, 36 + pcm.length, Endian.little);
  tag(8, 'WAVE');
  tag(12, 'fmt ');
  out.setUint32(16, 16, Endian.little);
  out.setUint16(20, 1, Endian.little);
  out.setUint16(22, 1, Endian.little);
  out.setUint32(24, rateHz, Endian.little);
  out.setUint32(28, rateHz * 2, Endian.little);
  out.setUint16(32, 2, Endian.little);
  out.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  out.setUint32(40, pcm.length, Endian.little);
  final bytes = out.buffer.asUint8List();
  bytes.setRange(44, bytes.length, pcm);
  return bytes;
}

/// The file name a sample is saved under, such as `mic-sample-linux-2026-11-22.wav`.
String micSampleFileName(DateTime when, String platform) {
  String two(int n) => n.toString().padLeft(2, '0');
  final date = '${when.year}-${two(when.month)}-${two(when.day)}';
  final time = '${two(when.hour)}${two(when.minute)}${two(when.second)}';
  return 'mic-sample-$platform-$date-$time.wav';
}

/// Where a sample stands; [seconds] is how much audio has been kept.
class MicSampleProgress {
  const MicSampleProgress(this.seconds, {this.total = kMicSampleSeconds});

  final int seconds;
  final int total;

  int get remaining => (total - seconds).clamp(0, total);
}

/// Opens [source], keeps [seconds] of the raw capture and hands back the WAV.
///
/// The countdown counts samples kept, not wall time, so a stalled microphone
/// shows as no progress and ends as a failure instead of a short file.
class MicSampleRecorder {
  MicSampleRecorder({
    required MicSampleSource source,
    this.seconds = kMicSampleSeconds,
    this.interval = const Duration(milliseconds: 200),
    this.stallTimeout = const Duration(seconds: 5),
  }) : _source = source;

  final int seconds;
  final Duration interval;

  /// Without a new sample for this long, the microphone is called silent.
  final Duration stallTimeout;
  final MicSampleSource _source;
  final _progress = StreamController<MicSampleProgress>.broadcast();
  bool _cancelled = false;

  Stream<MicSampleProgress> get progress => _progress.stream;

  /// Ends the recording early; [record] then throws.
  void cancel() => _cancelled = true;

  Future<Uint8List> record(String? deviceId) async {
    final kept = BytesBuilder(copy: false);
    try {
      await _open(deviceId);
      await _source.start(seconds);
      _progress.add(MicSampleProgress(0, total: seconds));
      await _keep(kept);
    } finally {
      await _closeQuietly();
    }
    return wavFromPcm16(kept.takeBytes());
  }

  Future<void> _open(String? deviceId) async {
    try {
      await _source.open(deviceId);
    } on Object catch (error) {
      throw MicSampleException('The microphone would not open. $error');
    }
  }

  Future<void> _keep(BytesBuilder kept) async {
    final goal = seconds * kMicSampleRateHz * 2;
    var lastGrowth = Duration.zero;
    var clock = Duration.zero;
    while (kept.length < goal) {
      await Future<void>.delayed(interval);
      clock += interval;
      if (_cancelled) throw const MicSampleException('Recording stopped.');
      final chunk = await _source.take();
      if (chunk.skippedFrames > 0 || chunk.rateHz != kMicSampleRateHz) {
        throw const MicSampleException(
          'This microphone runs at a rate the sample cannot keep.',
        );
      }
      if (chunk.pcm.isNotEmpty) {
        kept.add(chunk.pcm);
        lastGrowth = clock;
      } else if (chunk.full) {
        break;
      } else if (clock - lastGrowth >= stallTimeout) {
        throw const MicSampleException('The microphone gave no audio.');
      }
      _progress.add(
        MicSampleProgress(kept.length ~/ (kMicSampleRateHz * 2),
            total: seconds),
      );
    }
  }

  Future<void> _closeQuietly() async {
    try {
      await _source.stop();
      await _source.close();
    } on Object {
      // Nothing left to tell the person: the sample is already kept or failed.
    }
  }

  Future<void> dispose() => _progress.close();
}
