// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone level shown outside a call, while a screen that wants it is
/// open and the app is focused; a live call's own meter takes over from it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/app_lifecycle.dart';
import 'mic_level_ballistics.dart';
import 'voice_flags.dart';
import 'voice_settings_controller.dart';

/// Overridden in tests with a preview over a fake capture.
final micPreviewFactoryProvider = Provider<MicPreview Function()>(
  (ref) => systemMicPreview,
);

/// Whether a call owns the microphone, so the preview must not open a second
/// capture.
final micPreviewBlockedProvider = Provider<bool>(
  (ref) => ref.watch(
    voiceFlagsProvider.select(
      (f) =>
          f.state == VoiceSessionState.connecting ||
          f.state == VoiceSessionState.connected,
    ),
  ),
);

/// Opens the preview capture while a screen holds it, a call is not up and the
/// app is focused, and closes it the moment any of those stops being true.
class MicPreviewController extends StateNotifier<MicPreviewReading> {
  MicPreviewController(this._ref)
    : super(const MicPreviewReading(MicPreviewStatus.idle)) {
    _ref.listen(micPreviewBlockedProvider, (_, _) => _sync());
    // The lifecycle notifier itself: a derived provider waits for a frame, and none comes once hidden.
    _ref.listen(appLifecycleProvider, (_, _) => _sync());
    _ref.listen(
      voiceSettingsControllerProvider.select((s) => s.audioInputDeviceId),
      (_, id) => unawaited(_preview?.start(id)),
    );
  }

  final Ref _ref;
  MicPreview? _preview;
  StreamSubscription<MicPreviewReading>? _readings;
  int _holds = 0;

  void acquire() {
    _holds++;
    _sync();
  }

  /// Leaves the last reading in place: the screen that wanted it is gone, and
  /// the next [acquire] replaces it before anything is drawn.
  void release() {
    _holds--;
    _sync(announce: false);
  }

  void _sync({bool announce = true}) {
    final wanted =
        _holds > 0 &&
        !_ref.read(micPreviewBlockedProvider) &&
        _ref.read(appLifecycleProvider) == AppLifecycleState.resumed;
    if (wanted && _preview == null) {
      final preview = _preview = _ref.read(micPreviewFactoryProvider)();
      _readings = preview.readings.listen((r) => state = r);
      state = preview.current;
      unawaited(
        preview.start(
          _ref.read(voiceSettingsControllerProvider).audioInputDeviceId,
        ),
      );
    } else if (!wanted && _preview != null) {
      _stop();
      if (announce) state = const MicPreviewReading(MicPreviewStatus.idle);
    }
  }

  void _stop() {
    unawaited(_readings?.cancel());
    _readings = null;
    unawaited(_preview?.dispose());
    _preview = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }
}

final micPreviewProvider =
    StateNotifierProvider<MicPreviewController, MicPreviewReading>(
      MicPreviewController.new,
    );

/// What a preview meter draws.
class MicMeterView {
  const MicMeterView(this.status, {this.levelDb, this.voice = false});

  final MicPreviewStatus status;

  /// Null until the capture is live.
  final double? levelDb;
  final bool voice;

  double get fraction => levelDb == null ? 0 : inputLevelFraction(levelDb!);
}

final micMeterProvider = Provider<MicMeterView>((ref) {
  final reading = ref.watch(micPreviewProvider);
  if (reading.status != MicPreviewStatus.live) {
    return MicMeterView(reading.status);
  }
  final level = ref.watch(micLevelBallisticsProvider).step(reading.levelDb);
  return MicMeterView(reading.status, levelDb: level, voice: reading.voice);
});

extension MicMeterCaption on MicMeterView {
  String get caption => switch (status) {
    MicPreviewStatus.live => 'Say something to see it move.',
    MicPreviewStatus.unavailable =>
      'This microphone is not coming through. Check its permission.',
    _ => 'Opening your microphone...',
  };
}
