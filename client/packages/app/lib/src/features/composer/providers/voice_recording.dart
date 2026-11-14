// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Recording a voice message: the state machine behind the composer's mic
/// button. The microphone sits behind [VoiceCaptureBackend], so a test drives
/// the whole flow with a fake and never opens a real audio device.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart';
import 'package:slimm_platform/platform.dart' show isLinuxHost;

import '../../../api_failure.dart';
import 'composer_actions.dart';
import 'voice_capture_record.dart';

/// The longest voice message; the server allows a few seconds more.
const kVoiceMaxDuration = Duration(minutes: 5);

/// A clip shorter than this is a stray tap, not a message.
const kVoiceMinDuration = Duration(milliseconds: 500);

/// How often the level is sampled, which is also the waveform's resolution.
const kVoiceTick = Duration(milliseconds: 100);

/// Levels the live meter keeps.
const kVoiceMeterBars = 32;

/// What the microphone produced, still as the encoded file.
class VoiceCapture {
  const VoiceCapture({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

/// The microphone and its encoder.
abstract class VoiceCaptureBackend {
  /// Starts capturing; false when the microphone may not be used.
  Future<bool> start();

  /// How loud it is now, 0 to 1.
  Future<double> level();

  /// Stops and returns the encoded file.
  Future<VoiceCapture?> stop();

  /// Stops and throws the audio away.
  Future<void> cancel();
}

/// A finished recording, ready to upload.
class VoiceClip {
  const VoiceClip({
    required this.capture,
    required this.duration,
    required this.waveform,
  });

  final VoiceCapture capture;
  final Duration duration;

  /// [VoiceInfo.buckets] loudness values from 0 to 255.
  final List<int> waveform;
}

enum VoicePhase { idle, starting, recording, stopped, uploading, failed }

class VoiceRecordingState {
  const VoiceRecordingState({
    this.phase = VoicePhase.idle,
    this.elapsed = Duration.zero,
    this.levels = const [],
    this.clip,
    this.error,
  });

  final VoicePhase phase;
  final Duration elapsed;

  /// The newest levels for the live meter, oldest first.
  final List<double> levels;

  /// Held once the recording has stopped, so a failed upload can be retried.
  final VoiceClip? clip;
  final String? error;

  bool get isActive => phase != VoicePhase.idle;

  /// Whether the 5 minute cap ended this recording.
  bool get hitCap =>
      phase == VoicePhase.stopped && elapsed >= kVoiceMaxDuration;
}

/// Reduces per-tick [levels] to [VoiceInfo.buckets] values, the loudest tick of
/// each bucket, scaled so the loudest bucket reaches the top.
List<int> buildWaveform(List<double> levels) {
  const buckets = VoiceInfo.buckets;
  if (levels.isEmpty) return List<int>.filled(buckets, 0);
  final raw = List<double>.generate(buckets, (i) {
    final from = (i * levels.length / buckets).floor();
    final to = math.max(from + 1, ((i + 1) * levels.length / buckets).ceil());
    return levels.sublist(from, math.min(to, levels.length)).reduce(math.max);
  });
  final peak = raw.reduce(math.max);
  // A near-silent clip stays quiet rather than being stretched into noise.
  final scale = peak > 0.05 ? 1 / peak : 1.0;
  return [for (final v in raw) (v * scale * 255).round().clamp(0, 255)];
}

/// The recorder of one channel's composer; autodisposed with it, which also
/// releases the microphone.
class VoiceRecorder
    extends AutoDisposeFamilyNotifier<VoiceRecordingState, String> {
  VoiceCaptureBackend? _backend;
  Timer? _timer;
  DateTime? _startedAt;
  final List<double> _samples = [];
  bool _sampling = false;

  /// Replaced in tests so elapsed time can be set by hand.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  @override
  VoiceRecordingState build(String channelId) {
    ref.onDispose(() {
      _timer?.cancel();
      unawaited(_backend?.cancel());
    });
    return const VoiceRecordingState();
  }

  Future<void> start() async {
    if (state.phase != VoicePhase.idle && state.phase != VoicePhase.failed) {
      return;
    }
    state = const VoiceRecordingState(phase: VoicePhase.starting);
    final backend = ref.read(voiceCaptureFactoryProvider)();
    try {
      if (!await backend.start()) {
        state = const VoiceRecordingState(
          phase: VoicePhase.failed,
          error:
              'Microphone access is off. Allow it in your device settings '
              'to record a voice message.',
        );
        return;
      }
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'The microphone could not start',
        error,
        stack,
      );
      state = VoiceRecordingState(
        phase: VoicePhase.failed,
        error: ref.read(voiceRecordingNeedsToolsProvider)
            ? 'Could not record. On Linux this needs ffmpeg and parecord '
                  '(pulseaudio-utils) installed.'
            : 'The microphone could not be opened.',
      );
      return;
    }
    _backend = backend;
    _samples.clear();
    _startedAt = now();
    state = const VoiceRecordingState(phase: VoicePhase.recording);
    _timer = Timer.periodic(kVoiceTick, (_) => unawaited(tick()));
  }

  /// One sample of the level and the clock; the timer calls it.
  @visibleForTesting
  Future<void> tick() async {
    final backend = _backend;
    if (state.phase != VoicePhase.recording || backend == null || _sampling) {
      return;
    }
    _sampling = true;
    try {
      final level = await backend.level();
      if (state.phase != VoicePhase.recording) return;
      _samples.add(level);
      final elapsed = now().difference(_startedAt!);
      final meter = _samples.length > kVoiceMeterBars
          ? _samples.sublist(_samples.length - kVoiceMeterBars)
          : List<double>.of(_samples);
      state = VoiceRecordingState(
        phase: VoicePhase.recording,
        elapsed: elapsed,
        levels: meter,
      );
      if (elapsed >= kVoiceMaxDuration) await stop();
    } finally {
      _sampling = false;
    }
  }

  /// Ends the recording and keeps the clip for [send]; a stray tap is dropped.
  Future<void> stop() async {
    final backend = _backend;
    if (state.phase != VoicePhase.recording || backend == null) return;
    _timer?.cancel();
    final elapsed = math.min(
      now().difference(_startedAt!).inMilliseconds,
      kVoiceMaxDuration.inMilliseconds,
    );
    final duration = Duration(milliseconds: elapsed);
    final capture = await backend.stop();
    _backend = null;
    if (capture == null || duration < kVoiceMinDuration) {
      state = const VoiceRecordingState();
      return;
    }
    state = VoiceRecordingState(
      phase: VoicePhase.stopped,
      elapsed: duration,
      clip: VoiceClip(
        capture: capture,
        duration: duration,
        waveform: buildWaveform(_samples),
      ),
    );
  }

  /// Throws the recording away, whether it is still running or already stopped.
  Future<void> cancel() async {
    _timer?.cancel();
    final backend = _backend;
    _backend = null;
    state = const VoiceRecordingState();
    await backend?.cancel();
  }

  /// Ends the recording if it is still running, uploads it as a voice message
  /// and returns the stored attachment with the bytes it was made from. A
  /// failure keeps the clip, so Send tries again.
  Future<(Attachment, Uint8List)?> send() async {
    if (state.phase == VoicePhase.recording) await stop();
    final clip = state.clip;
    if (clip == null || state.phase == VoicePhase.uploading) return null;
    state = VoiceRecordingState(
      phase: VoicePhase.uploading,
      elapsed: clip.duration,
      clip: clip,
    );
    try {
      final attachment = await ref
          .read(composerActionsProvider)
          .uploadVoice(
            clip.capture.bytes,
            filename: clip.capture.filename,
            channelId: arg,
            voice: VoiceInfo(duration: clip.duration, waveform: clip.waveform),
          );
      state = const VoiceRecordingState();
      return (attachment, clip.capture.bytes);
    } on ApiException catch (error) {
      _failUpload(clip, describeApiFailure('send the voice message', error));
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'A voice message upload failed',
        error,
        stack,
      );
      _failUpload(clip, 'The voice message could not be sent.');
    }
    return null;
  }

  void _failUpload(VoiceClip clip, String message) {
    state = VoiceRecordingState(
      phase: VoicePhase.failed,
      elapsed: clip.duration,
      clip: clip,
      error: message,
    );
  }
}

final voiceRecorderProvider = NotifierProvider.autoDispose
    .family<VoiceRecorder, VoiceRecordingState, String>(VoiceRecorder.new);

/// Linux records through the ffmpeg and parecord programs, so a failed start
/// there is most often one of them missing. Replaced in tests.
final voiceRecordingNeedsToolsProvider = Provider<bool>((ref) => isLinuxHost);

/// Builds the microphone only when a recording starts, so nothing native is
/// touched by a composer that never records. Replaced in tests.
final voiceCaptureFactoryProvider = Provider<VoiceCaptureBackend Function()>(
  (ref) => RecordVoiceCapture.new,
);
