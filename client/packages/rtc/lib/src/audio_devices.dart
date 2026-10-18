// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enumerating the microphones and speakers a device offers, `camera_devices.dart`'s
/// own shape for audio.
library;

import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogTag;

import 'pulse_audio.dart';
import 'voice_models.dart';

/// The seam. The default implementation asks the platform's own device
/// list; a test supplies its own.
abstract class AudioDevices {
  Future<List<AudioDevice>> inputs();
  Future<List<AudioDevice>> outputs();

  /// The entry the platform itself lists as "whatever the system default is",
  /// or null where it lists none. [inputs] strips it from the picker.
  Future<AudioDevice?> systemDefaultInput();
  Future<AudioDevice?> systemDefaultOutput();

  /// Fires whenever the platform's own device list changes - a headset
  /// plugged in or removed - so a picker can refresh without polling.
  Stream<void> get onChange;
}

class HardwareAudioDevices implements AudioDevices {
  const HardwareAudioDevices();

  /// libwebrtc's list, unless it is empty on Linux, where the sound server's
  /// own list stands in; see `pulse_audio_io.dart`.
  @override
  Future<List<AudioDevice>> inputs() async {
    final listed = await _listedOrWarmed(lk.Hardware.instance.audioInputs);
    if (listed.isNotEmpty || !PulseAudio.supported) return listed;
    return await PulseAudio().sources() ?? listed;
  }

  @override
  Future<List<AudioDevice>> outputs() async {
    final listed = await _listedOrWarmed(lk.Hardware.instance.audioOutputs);
    if (listed.isNotEmpty || !PulseAudio.supported) return listed;
    return await PulseAudio().sinks() ?? listed;
  }

  /// On Windows libwebrtc lists no audio devices until something has opened
  /// audio, so a new member saw an empty microphone list until they joined a
  /// call. An empty first answer there opens the mic for a moment and asks again.
  static Future<List<AudioDevice>> _listedOrWarmed(
    Future<List<lk.MediaDevice>> Function() list,
  ) async {
    final listed = withoutPseudoDefaults(_toAudioDevices(await list()));
    if (listed.isNotEmpty || lk.lkPlatform() != lk.PlatformType.windows) {
      return listed;
    }
    await _warmAudio();
    return withoutPseudoDefaults(_toAudioDevices(await list()));
  }

  static Future<void>? _warming;

  static Future<void> _warmAudio() => _warming ??= () async {
        try {
          final stream = await rtc.navigator.mediaDevices
              .getUserMedia({'audio': true, 'video': false});
          for (final track in stream.getTracks()) {
            await track.stop();
          }
          await stream.dispose();
        } on Object catch (error, stack) {
          // Refused or no microphone: the empty list is then the true answer.
          AppLog.swallowed(
              LogTag.voice,
              'Could not open the microphone to list audio devices',
              error,
              stack);
        } finally {
          _warming = null;
        }
      }();

  @override
  Future<AudioDevice?> systemDefaultInput() async => _systemDefaultOf(
      _toAudioDevices(await lk.Hardware.instance.audioInputs()));

  @override
  Future<AudioDevice?> systemDefaultOutput() async => _systemDefaultOf(
        _toAudioDevices(await lk.Hardware.instance.audioOutputs()),
      );

  @override
  Stream<void> get onChange =>
      lk.Hardware.instance.onDeviceChange.stream.map((_) {});
}

AudioDevice? _systemDefaultOf(List<AudioDevice> devices) =>
    devices.where((d) => d.id == 'default').firstOrNull;

List<AudioDevice> _toAudioDevices(List<lk.MediaDevice> devices) => [
      for (final device in devices)
        AudioDevice(
          id: device.deviceId,
          label: device.label,
          groupId: device.groupId,
        ),
    ];

/// Resolves a persisted device choice against what is actually plugged in
/// right now.
///
/// Null always means the system default. A non-null [preferredId] that
/// [devices] no longer lists - unplugged since it was chosen - falls back to
/// the default the same way, so a picker can say so quietly rather than
/// silently failing to find it on every rebuild.
AudioDevice? resolveAudioDevice(
  List<AudioDevice> devices,
  String? preferredId,
) {
  if (preferredId == null) return null;
  for (final device in devices) {
    if (device.id == preferredId) return device;
  }
  return null;
}

/// Drops the browser's own stand-ins for "whatever the system default is".
///
/// Chrome lists a `default` (and on Windows a `communications`) entry ahead
/// of the real devices; seen live, that put "Default" and this app's own
/// "System default" in the same picker meaning the same thing. Null already
/// means the system default here, so the pseudo entries add a duplicate and
/// nothing else.
///
/// A browser that has not been granted the microphone yet lists devices with
/// an empty id and label; none of them can be chosen, and an empty id is what
/// the picker uses for the system default, so they are dropped too.
List<AudioDevice> withoutPseudoDefaults(List<AudioDevice> devices) => [
      for (final device in devices)
        if (device.id.isNotEmpty &&
            device.id != 'default' &&
            device.id != 'communications')
          device,
    ];
