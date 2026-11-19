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
import 'package:slimm_platform/platform.dart'
    show isAndroidHost, isIOSHost, isLinuxHost;
import 'package:slimm_rtc/rtc.dart' show AudioDevice, resolveAudioDevice;

import '../../../api_failure.dart';
import '../../../audio/call_start_yields.dart';
import '../../../audio/call_holds_audio_session.dart';
import '../../../providers/session_provider.dart';
import '../../accounts/providers/account_slot.dart';
import '../../voice/providers/voice_controller.dart';
import '../../voice/providers/voice_settings_storage.dart';
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

/// [stopping] is the encoder finishing the file, which a Discard still overtakes.
enum VoicePhase {
  idle,
  starting,
  recording,
  stopping,
  stopped,
  uploading,
  failed,
}

class VoiceRecordingState {
  const VoiceRecordingState({
    this.phase = VoicePhase.idle,
    this.elapsed = Duration.zero,
    this.levels = const [],
    this.clip,
    this.error,
    this.stoppedForCall = false,
  });

  final VoicePhase phase;
  final Duration elapsed;

  /// The newest levels for the live meter, oldest first.
  final List<double> levels;

  /// Held once the recording has stopped, so a failed upload can be retried.
  final VoiceClip? clip;
  final String? error;

  /// Whether a call starting ended this recording, which the bar says.
  final bool stoppedForCall;

  bool get isActive => phase != VoicePhase.idle;

  /// Audio not yet sent or thrown away, which keeps the recorder past its composer.
  bool get holdsAudio =>
      phase == VoicePhase.recording ||
      phase == VoicePhase.stopping ||
      clip != null;

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

/// One channel's recorder. It outlives the composer while it holds audio and
/// otherwise goes with it, which releases the microphone.
class VoiceRecorder
    extends AutoDisposeFamilyNotifier<VoiceRecordingState, String> {
  VoiceCaptureBackend? _backend;
  KeepAliveLink? _hold;

  /// Bumped by every start, cancel and disposal; a start or stop that returns to a newer number lets go.
  int _attempt = 0;
  Timer? _timer;
  DateTime? _startedAt;
  final List<double> _samples = [];
  bool _sampling = false;

  /// Every microphone close still running, which a call starting waits for:
  /// on Android a close clears the Bluetooth route the call takes.
  Future<void> _closing = Future.value();

  /// Replaced in tests so elapsed time can be set by hand.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  @override
  VoiceRecordingState build(String channelId) {
    final yields = ref.read(callStartYieldsProvider);
    final unregister = yields.add(() => _giveWay(forCall: true));
    final signIns = _dropOnAccountChange();
    ref.listen(accountActiveProvider, (_, onScreen) {
      if (!onScreen) unawaited(_giveWay(forCall: false));
    });
    listenSelf((_, next) {
      _holdWhile(next.holdsAudio);
      _claimWhile(next.phase == VoicePhase.recording);
    });
    ref.onDispose(() {
      unregister();
      unawaited(signIns.cancel());
      _hold = null;
      _attempt++;
      _timer?.cancel();
      if (_backend case final backend?) _track(backend.cancel());
      // A microphone still closing as the recorder goes keeps the next call waiting.
      final closing = _closing;
      unawaited(closing.whenComplete(yields.add(() => closing)));
    });
    return const VoiceRecordingState();
  }

  /// Adds [close] to the microphone closes a call starting waits for.
  void _track(Future<Object?> close) {
    final quiet = close.then<void>((_) {}, onError: (Object _) {});
    final before = _closing;
    _closing = before.then((_) => quiet);
  }

  Future<void> start() async {
    if (state.phase != VoicePhase.idle && state.phase != VoicePhase.failed) {
      return;
    }
    // On a phone the call holds the one audio session, which the recorder would reconfigure.
    if (ref.read(voiceRecordingYieldsToCallProvider) &&
        ref.read(callHoldsAudioSessionProvider)()) {
      state = const VoiceRecordingState(
        phase: VoicePhase.failed,
        error: 'Leave the call to record a voice message.',
      );
      return;
    }
    state = const VoiceRecordingState(phase: VoicePhase.starting);
    final attempt = ++_attempt;
    if (_otherRecording() case final other?) {
      await other.stop();
      if (attempt != _attempt) return;
    }
    final backend = ref.read(voiceCaptureFactoryProvider)();
    final needsTools = ref.read(voiceRecordingNeedsToolsProvider);
    bool opened;
    try {
      opened = await backend.start();
    } on Object catch (error, stack) {
      if (_superseded(attempt, backend)) return;
      AppLog.swallowed(
        LogTag.voice,
        'The microphone could not start',
        error,
        stack,
      );
      state = VoiceRecordingState(
        phase: VoicePhase.failed,
        error: needsTools
            ? 'Could not record. On Linux this needs parecord '
                  '(pulseaudio-utils) installed.'
            : 'The microphone could not be opened.',
      );
      return;
    }
    if (_superseded(attempt, backend)) return;
    if (!opened) {
      state = const VoiceRecordingState(
        phase: VoicePhase.failed,
        error:
            'Microphone access is off. Allow it in your device settings '
            'to record a voice message.',
      );
      return;
    }
    _backend = backend;
    _samples.clear();
    _startedAt = now();
    state = const VoiceRecordingState(phase: VoicePhase.recording);
    _timer = Timer.periodic(kVoiceTick, (_) => unawaited(tick()));
  }

  /// Whether a cancel or disposal overtook the start of [attempt]; if so its microphone is closed here.
  bool _superseded(int attempt, VoiceCaptureBackend backend) {
    if (attempt == _attempt) return false;
    _track(backend.cancel());
    return true;
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

  void _holdWhile(bool holdsAudio) {
    if (holdsAudio) {
      _hold ??= ref.keepAlive();
    } else {
      _hold?.close();
      _hold = null;
    }
  }

  /// Names this channel in [recordingVoiceChannelProvider] while it records.
  void _claimWhile(bool recording) {
    final live = ref.read(recordingVoiceChannelProvider.notifier);
    if (recording && live.state != arg) {
      final other = _otherRecording();
      live.state = arg;
      if (other != null) unawaited(other.stop());
    } else if (!recording && live.state == arg) {
      live.state = null;
    }
  }

  /// Another channel's recording, which stops and keeps its clip: one records at a time.
  VoiceRecorder? _otherRecording() {
    final other = ref.read(recordingVoiceChannelProvider);
    if (other == null || other == arg) return null;
    return ref.read(voiceRecorderProvider(other).notifier);
  }

  /// Another account's audio is never kept for this one, the boundary the drafts keep.
  StreamSubscription<TokenPair?> _dropOnAccountChange() {
    final session = ref.read(sessionProvider);
    var account = session.tokens?.userId;
    return session.changes.listen((tokens) {
      if (tokens?.userId == account) return;
      account = tokens?.userId;
      unawaited(cancel());
    });
  }

  /// A call starting, or its account leaving the screen, stops a recording and
  /// keeps the clip; one still opening is dropped. Either way it waits for
  /// every microphone still closing.
  Future<void> _giveWay({required bool forCall}) async {
    if (state.phase == VoicePhase.starting) {
      await cancel();
    } else if (state.phase == VoicePhase.recording) {
      await _finish(forCall: forCall);
    }
    await _closing;
  }

  /// Ends the recording and keeps the clip for [send]; a stray tap is dropped.
  Future<void> stop() => _finish(forCall: false);

  Future<void> _finish({required bool forCall}) async {
    final backend = _backend;
    if (state.phase != VoicePhase.recording || backend == null) return;
    _timer?.cancel();
    _backend = null;
    final attempt = _attempt;
    final elapsed = math.min(
      now().difference(_startedAt!).inMilliseconds,
      kVoiceMaxDuration.inMilliseconds,
    );
    final duration = Duration(milliseconds: elapsed);
    state = VoiceRecordingState(
      phase: VoicePhase.stopping,
      elapsed: duration,
      levels: state.levels,
    );
    final VoiceCapture? capture;
    try {
      final stopping = backend.stop();
      _track(stopping);
      capture = await stopping;
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'A recording could not be finished',
        error,
        stack,
      );
      if (attempt == _attempt) {
        state = const VoiceRecordingState(
          phase: VoicePhase.failed,
          error: 'The recording could not be finished.',
        );
      }
      return;
    }
    if (attempt != _attempt) return;
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
      stoppedForCall: forCall,
    );
  }

  /// Throws the recording away, whether it is still running or already stopped.
  Future<void> cancel() async {
    _attempt++;
    _timer?.cancel();
    final backend = _backend;
    _backend = null;
    state = const VoiceRecordingState();
    if (backend == null) return;
    final closing = backend.cancel();
    _track(closing);
    await closing;
  }

  /// Ends the recording if it is still running, uploads it as a voice message
  /// and returns the stored attachment with the bytes it was made from. A
  /// failure keeps the clip, so Send tries again, and so does a [refusal],
  /// asked before the upload and again once it is stored. A discard while it
  /// uploads wins: the clip is neither returned nor kept.
  Future<(Attachment, Uint8List)?> send({String? Function()? refusal}) async {
    if (state.phase == VoicePhase.recording) await stop();
    final clip = state.clip;
    if (clip == null || state.phase == VoicePhase.uploading) return null;
    if (refusal?.call() case final reason?) {
      _failUpload(clip, reason);
      return null;
    }
    final attempt = _attempt;
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
      if (attempt != _attempt) return null;
      if (refusal?.call() case final reason?) {
        _failUpload(clip, reason);
        return null;
      }
      state = const VoiceRecordingState();
      return (attachment, clip.capture.bytes);
    } on ApiException catch (error) {
      if (attempt != _attempt) return null;
      _failUpload(clip, describeApiFailure('send the voice message', error));
    } on Object catch (error, stack) {
      AppLog.swallowed(
        LogTag.voice,
        'A voice message upload failed',
        error,
        stack,
      );
      if (attempt != _attempt) return null;
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

/// The channel whose voice message is recording now, if any.
final recordingVoiceChannelProvider = StateProvider<String?>((ref) => null);

/// Linux records through the parecord program, so a failed start there is
/// most often it missing. Replaced in tests.
final voiceRecordingNeedsToolsProvider = Provider<bool>((ref) => isLinuxHost);

/// Whether a call rules out recording: on iPhone and Android both share one
/// audio session. Replaced in tests.
final voiceRecordingYieldsToCallProvider = Provider<bool>(
  (ref) => isIOSHost || isAndroidHost,
);

/// Builds the microphone only when a recording starts, so nothing native is
/// touched by a composer that never records. Replaced in tests.
final voiceCaptureFactoryProvider = Provider<VoiceCaptureBackend Function()>(
  (ref) =>
      () => RecordVoiceCapture(chosenInput: () => chosenVoiceInput(ref)),
);

/// The microphone picked in Voice settings, wherever a call honours the pick;
/// null for the system default.
Future<AudioDevice?> chosenVoiceInput(Ref ref) async {
  final (id, _) = await loadAudioDevicePreferences(ref);
  final devices = ref.read(voiceControllerProvider.notifier).devices;
  if (id == null || !devices.supportsAudioInputSelection) return null;
  return resolveAudioDevice(await devices.audioInputDevices(), id) ??
      AudioDevice(id: id, label: '');
}
