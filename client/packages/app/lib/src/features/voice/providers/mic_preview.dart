// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The microphone level shown outside a call, while a screen that wants it is
/// open and the app is focused; a live call's own meter takes over from it.
library;

import 'dart:async';

import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_platform/platform.dart' show isDesktopHost;
import 'package:slimm_rtc/rtc.dart';

import '../../../providers/app_lifecycle.dart';
import 'mic_level_ballistics.dart';
import 'voice_flags.dart';
import 'voice_settings_controller.dart';

/// Overridden in tests with a preview over a fake capture.
final micPreviewFactoryProvider = Provider<MicPreview Function()>(
  (ref) => systemMicPreview,
);

/// Phones open the capture only after a tap, so the pane never touches the
/// microphone or speaker on its own. Overridden in tests.
final micPreviewNeedsTapProvider = Provider<bool>((ref) => !isDesktopHost);

/// Set by the tap, cleared when the screen closes or the app is backgrounded.
final micPreviewArmedProvider = StateProvider<bool>((ref) => false);

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

  bool get _armed =>
      _ref.read(micPreviewArmedProvider) ||
      !_ref.read(micPreviewNeedsTapProvider);

  void _disarm() {
    if (_ref.read(micPreviewArmedProvider)) {
      _ref.read(micPreviewArmedProvider.notifier).state = false;
    }
  }

  /// An explicit tap on a phone's "Test microphone".
  void arm() {
    _ref.read(micPreviewArmedProvider.notifier).state = true;
    _sync();
  }

  /// "Stop test": closes the microphone while the pane stays open.
  void stop() {
    _disarm();
    _sync();
  }

  void acquire() {
    _holds++;
    _sync();
  }

  /// Leaves the last reading in place: the screen that wanted it is gone, and
  /// the next [acquire] replaces it before anything is drawn.
  void release() {
    _holds--;
    if (_holds <= 0) _disarm();
    _sync(announce: false);
  }

  void _sync({bool announce = true}) {
    final lifecycle = _ref.read(appLifecycleProvider);
    final resumed = lifecycle == AppLifecycleState.resumed;
    // Inactive is also Android's permission prompt, which the tap itself raises.
    if (!resumed && lifecycle != AppLifecycleState.inactive) _disarm();
    final wanted =
        _holds > 0 &&
        _armed &&
        !_ref.read(micPreviewBlockedProvider) &&
        resumed;
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
  const MicMeterView(
    this.status, {
    this.levelDb,
    this.voice = false,
    this.awaitingTap = false,
  });

  final MicPreviewStatus status;

  /// A phone that has not had its "Test microphone" tap yet.
  final bool awaitingTap;

  /// Null until the capture is live.
  final double? levelDb;
  final bool voice;

  double get fraction => levelDb == null ? 0 : inputLevelFraction(levelDb!);
}

final micMeterProvider = Provider<MicMeterView>((ref) {
  final reading = ref.watch(micPreviewProvider);
  if (reading.status != MicPreviewStatus.live) {
    final awaitingTap =
        ref.watch(micPreviewNeedsTapProvider) &&
        !ref.watch(micPreviewArmedProvider);
    return MicMeterView(reading.status, awaitingTap: awaitingTap);
  }
  final level = ref.watch(micLevelBallisticsProvider).step(reading.levelDb);
  return MicMeterView(reading.status, levelDb: level, voice: reading.voice);
});

extension MicMeterCaption on MicMeterView {
  String get caption => switch (status) {
    MicPreviewStatus.idle when awaitingTap =>
      'Tap Test microphone to see your level.',
    MicPreviewStatus.live => 'Say something to see it move.',
    MicPreviewStatus.unavailable =>
      'This microphone is not coming through. Check its permission.',
    _ => 'Opening your microphone...',
  };
}

/// Where automatic sensitivity would put the line, learned from the preview
/// level while no call is up, so the settings meter shows it working.
final previewAutoThresholdProvider = StreamProvider.autoDispose<double>((ref) {
  final estimator = NoiseFloorEstimator(
    initialThresholdDb: ref.read(
      voiceSettingsControllerProvider.select((s) => s.inputThresholdDb),
    ),
  );
  final out = StreamController<double>();
  ref.onDispose(out.close);
  ref.listen(micPreviewProvider, (_, reading) {
    if (reading.status != MicPreviewStatus.live) return;
    out.add(estimator.add(reading.levelDb));
  });
  return out.stream;
});
