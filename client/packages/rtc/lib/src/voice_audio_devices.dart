// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A voice session's microphone and speaker picker.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart'
    show AppLog, LogLevel, LogTag, reportFailure;

import 'audio_device_switching.dart';
import 'audio_devices.dart';
import 'mic_port.dart';
import 'pulse_audio.dart';
import 'voice_models.dart' show AudioDevice;

/// What [VoiceAudioDevices] needs from the session that owns it.
class VoiceAudioDevicesHost {
  const VoiceAudioDevicesHost({
    required this.room,
    required this.noteError,
    required this.supportsInputGate,
    required this.applyInputGate,
    required this.diag,
  });

  final lk.Room? Function() room;
  final void Function(Object error) noteError;
  final bool Function() supportsInputGate;
  final Future<void> Function() applyInputGate;
  final void Function(String line, {LogLevel level}) diag;
}

/// Lists, selects and follows the microphones and speakers a call uses, on top
/// of [AudioDeviceSwitching].
class VoiceAudioDevices {
  VoiceAudioDevices(
    this._host,
    this._mic, {
    AudioDevices? devices,
    LiveOutputSwitch? liveOutput,
    LiveInputSwitch? liveInput,
    PulseAudio? pulse,
  }) {
    switching = AudioDeviceSwitching(
      // The warm-up must know whether a call holds the devices; see [HardwareAudioDevices.inCall].
      devices ??
          HardwareAudioDevices(
            inCall: () => _host.room() != null,
            chosenInput: () => switching.chosenInput,
          ),
      liveOutput: liveOutput,
      log: _host.diag,
      liveInput: liveInput,
      // Injected devices mean a test, which must not talk to the real sound server.
      pulse: pulse ?? (devices == null ? null : PulseAudio.inert()),
    );
  }

  final VoiceAudioDevicesHost _host;
  final MicPort _mic;
  late final AudioDeviceSwitching switching;

  /// Whether picking a specific microphone actually changes the live call;
  /// see [AudioDeviceSwitching.supportsInputSelection].
  bool get supportsInputSelection => switching.supportsInputSelection;

  /// Whether picking a specific speaker actually changes playback; see
  /// [AudioDeviceSwitching.supportsOutputSelection].
  bool get supportsOutputSelection => switching.supportsOutputSelection;

  /// The id of the speaker playback is routed to, null for the system default.
  String? get outputInUse => switching.outputInUse;

  /// The id of the microphone capture is on, null for the system default.
  String? get inputInUse => switching.inputInUse;

  /// Fires when the platform's own device list changes, so a picker can
  /// refresh without polling.
  Stream<void> get changes => switching.onChange;

  /// What the next [MicPort.setEnabled] opens with. [reopen] makes LiveKit
  /// restart a capture that was released, rather than just unmute it.
  lk.AudioCaptureOptions openCaptureOptions({required bool reopen}) =>
      switching.captureOptions().copyWith(stopAudioCaptureOnMute: reopen);

  /// A new stream starts on the sound server's default; this moves it onto
  /// the pick, now and again once playback has had a moment to open.
  void followPreferred() {
    // A reopened capture has no gate or suppressor on it until they are sent again.
    unawaited(_host.applyInputGate());
    Future<void> apply() async {
      try {
        await switching.applyServerRouting();
        await switching.reapplyOutput(_host.room());
      } catch (error, stack) {
        AppLog.swallowed(LogTag.voice,
            'Could not move the call audio to the chosen device', error, stack);
      }
    }

    unawaited(apply());
    unawaited(Future<void>.delayed(const Duration(seconds: 3), apply));
  }

  /// The microphones this platform offers, for the picker.
  Future<List<AudioDevice>> inputs() => _list(switching.inputs);

  /// The speakers this platform offers, for the picker.
  Future<List<AudioDevice>> outputs() => _list(switching.outputs);

  /// A device list that cannot be read must not stop a join.
  Future<void> forgetUnplugged() async {
    try {
      await switching.forgetUnpluggedPreferences();
    } catch (error, stack) {
      AppLog.swallowed(
          LogTag.voice,
          'Could not forget unplugged audio devices; keeping the saved ones',
          error,
          stack);
    }
  }

  Future<List<AudioDevice>> _list(
    Future<List<AudioDevice>> Function() list,
  ) async {
    try {
      return await list();
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'list audio devices', e, stack);
      _host.noteError(e);
      return const [];
    }
  }

  /// Switches the published microphone to [device] (null for the system
  /// default), live where this platform honours it; [remember] false moves
  /// only the live capture, for a call-only fallback.
  Future<bool> selectInput(AudioDevice? device, {required bool remember}) =>
      _trySelect(() async {
        // The reopen a switch does reuses the track's own options, not the room's.
        if (_host.supportsInputGate()) {
          _mic.adoptOptions(switching.captureOptions());
        }
        await switching.selectInput(_host.room(), device, remember: remember);
      });

  /// [selectInput]'s counterpart for local playback.
  Future<bool> selectOutput(AudioDevice? device, {required bool remember}) =>
      _trySelect(
        () => switching.selectOutput(_host.room(), device, remember: remember),
      );

  Future<bool> _trySelect(Future<void> Function() run) async {
    try {
      await run();
      return true;
    } catch (e, stack) {
      reportFailure(LogTag.voice, 'choose the audio device', e, stack);
      _host.noteError(e);
      return false;
    }
  }
}
