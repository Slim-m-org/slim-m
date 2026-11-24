// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Records a raw microphone sample for the noise corpus and saves it on this device.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;
import 'package:slimm_rtc/rtc.dart';

import '../../../downloads/download_target.dart';
import '../../../providers/app_lifecycle.dart';
import '../../../providers/providers.dart';
import '../../voice/providers/mic_preview.dart';
import '../../voice/providers/voice_settings_controller.dart';

/// Overridden in tests with a recorder over a fake capture.
final micSampleRecorderFactoryProvider = Provider<MicSampleRecorder Function()>(
  (ref) => systemMicSampleRecorder,
);

/// Only a host whose capture chain can be tapped offers the sample.
final micSampleSupportedProvider = Provider<bool>((ref) => supportsMicSample);

/// Saves the WAV and says whether the person kept it; overridden in tests.
final micSampleSaverProvider =
    Provider<Future<bool> Function(String name, Uint8List wav)>(
      (ref) => saveToDownloads,
    );

final micSampleClockProvider = Provider<DateTime Function()>(
  (ref) => DateTime.now,
);

Future<bool> saveToDownloads(String name, Uint8List wav) async {
  final target = await openDownloadTarget(name);
  if (target == null) return false;
  try {
    await target.write(wav);
    return await target.finish();
  } on Object {
    await target.discard();
    rethrow;
  }
}

enum MicSamplePhase { idle, recording, saved, failed }

class MicSampleState {
  const MicSampleState({
    this.phase = MicSamplePhase.idle,
    this.secondsKept = 0,
    this.total = kMicSampleSeconds,
    this.fileName,
    this.error,
  });

  final MicSamplePhase phase;
  final int secondsKept;
  final int total;
  final String? fileName;
  final String? error;

  bool get recording => phase == MicSamplePhase.recording;
  int get secondsLeft => (total - secondsKept).clamp(0, total);
}

class MicSampleController extends Notifier<MicSampleState> {
  @override
  MicSampleState build() {
    ref.listen(micPreviewBlockedProvider, (_, blocked) {
      if (blocked) stop();
    });
    ref.listen(sessionProvider, (_, _) => stop());
    ref.listen(appVisibleProvider, (_, visible) {
      if (!visible) stop();
    });
    ref.onDispose(stop);
    return const MicSampleState();
  }

  MicSampleRecorder? _recorder;
  bool _stopped = false;

  Future<void> start() async {
    if (state.recording || ref.read(micPreviewBlockedProvider)) return;
    _stopped = false;
    final recorder = _recorder = ref.read(micSampleRecorderFactoryProvider)();
    state = MicSampleState(
      phase: MicSamplePhase.recording,
      total: recorder.seconds,
    );
    final progress = recorder.progress.listen(
      (p) => state = MicSampleState(
        phase: MicSamplePhase.recording,
        secondsKept: p.seconds,
        total: p.total,
      ),
    );
    try {
      final wav = await recorder.record(
        ref.read(voiceSettingsControllerProvider).audioInputDeviceId,
      );
      await _save(wav);
    } on MicSampleException catch (e) {
      if (_stopped) {
        state = const MicSampleState();
      } else {
        _fail(e.message);
      }
    } on Object catch (error, stack) {
      AppLog.swallowed(LogTag.voice, 'The mic sample failed', error, stack);
      _fail('The sample could not be saved. Try again.');
    } finally {
      await progress.cancel();
      _recorder = null;
      unawaited(recorder.dispose());
    }
  }

  Future<void> _save(Uint8List wav) async {
    final name = micSampleFileName(
      ref.read(micSampleClockProvider)(),
      defaultTargetPlatform.name,
    );
    final kept = await ref.read(micSampleSaverProvider)(name, wav);
    state = kept
        ? MicSampleState(phase: MicSamplePhase.saved, fileName: name)
        : const MicSampleState();
  }

  void _fail(String message) {
    state = MicSampleState(phase: MicSamplePhase.failed, error: message);
  }

  void stop() {
    _stopped = true;
    _recorder?.cancel();
  }

  void dismiss() => state = const MicSampleState();
}

final micSampleControllerProvider =
    NotifierProvider<MicSampleController, MicSampleState>(
      MicSampleController.new,
    );
