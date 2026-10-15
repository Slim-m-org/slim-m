// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking a microphone or speaker, `camera_switching.dart`'s own shape for
/// audio: the room is handed in per call rather than held here, so this
/// stays a plain, test-friendly class with no LiveKit connection of its own.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_devices.dart';
import 'voice_models.dart';

/// Points a live [lk.Room]'s capture at [device]. A seam so tests can see
/// what a mid-call pick sends without a native audio stack.
typedef LiveInputSwitch = Future<void> Function(
  lk.Room room,
  lk.MediaDevice device,
);

class AudioDeviceSwitching {
  AudioDeviceSwitching(this._devices, {LiveInputSwitch? liveInput})
      : _liveInput = liveInput ?? switchLiveInput;

  final AudioDevices _devices;
  final LiveInputSwitch _liveInput;

  String? _preferredInputId;
  String? _preferredOutputId;

  /// Whether picking a specific microphone actually changes the live call.
  /// False on mobile: `Hardware.selectAudioInput` (livekit_client 2.10.0,
  /// the pinned version) warns and returns without doing anything for iOS
  /// and Android, so offering a picker there would be a control that
  /// quietly does nothing.
  bool get supportsInputSelection => !lk.lkPlatformIsMobile();

  /// Whether picking a specific speaker actually changes playback. False on
  /// web and iOS: `Room.setAudioOutputDevice` falls through to
  /// `Hardware.selectAudioOutput`, which explicitly excludes both, and
  /// browser support for the web-only alternative (`setSinkId`) is not
  /// consistent enough across this app's targets to offer a picker that
  /// would work on some of the fleet and silently not on the rest.
  bool get supportsOutputSelection =>
      !lk.lkPlatformIs(lk.PlatformType.web) &&
      !lk.lkPlatformIs(lk.PlatformType.iOS);

  Future<List<AudioDevice>> inputs() => _devices.inputs();
  Future<List<AudioDevice>> outputs() => _devices.outputs();
  Stream<void> get onChange => _devices.onChange;

  /// The [lk.RoomOptions] a fresh join should carry, layering whatever is
  /// currently preferred onto [base], so a device chosen before joining
  /// takes effect from the very first published track rather than only
  /// after a live switch; see [selectInput]/[selectOutput] for the mid-call
  /// path.
  lk.RoomOptions roomOptions(lk.RoomOptions base) => base.copyWith(
        defaultAudioCaptureOptions: lk.AudioCaptureOptions(
          deviceId: _preferredInputId,
          // Reopening on unmute flips Bluetooth profiles and clips the first syllable.
          stopAudioCaptureOnMute: false,
        ),
        defaultAudioOutputOptions: lk.AudioOutputOptions(
          deviceId: _preferredOutputId,
        ),
      );

  /// Forgets a remembered microphone or speaker that is no longer plugged in,
  /// so the next [roomOptions] asks for the system default instead of a device
  /// the browser would refuse outright.
  Future<void> forgetUnpluggedPreferences() async {
    final input = _preferredInputId;
    if (input != null && resolveAudioDevice(await inputs(), input) == null) {
      _preferredInputId = null;
    }
    final output = _preferredOutputId;
    if (output != null && resolveAudioDevice(await outputs(), output) == null) {
      _preferredOutputId = null;
    }
  }

  /// Applies [device] to [room]'s live input when one exists and this
  /// platform honours it, and remembers it either way for the next
  /// [roomOptions].
  ///
  /// Null means the system default. Mid-call, that selects the platform's
  /// own default entry, and changes nothing live where it lists none: the
  /// first physical device is not the system default.
  Future<void> selectInput(lk.Room? room, AudioDevice? device) async {
    _preferredInputId = device?.id;
    if (room == null || !supportsInputSelection) return;
    final target = device ?? await _devices.systemDefaultInput();
    if (target == null) return;
    await _liveInput(room, _asMediaDevice(target, 'audioinput'));
  }

  /// `Room.setAudioInputDevice` only sets the native recording device and the
  /// room default on desktop, so the published track kept its own old
  /// `deviceId`: it went on capturing the previous microphone, and any later
  /// restart (unmute, push-to-talk) re-opened that one.
  static Future<void> switchLiveInput(
    lk.Room room,
    lk.MediaDevice device,
  ) async {
    await room.setAudioInputDevice(device);
    for (final publication
        in room.localParticipant?.audioTrackPublications ?? const []) {
      final track = publication.track;
      if (track is lk.LocalAudioTrack) await track.setDeviceId(device.deviceId);
    }
  }

  /// [selectInput]'s counterpart for output.
  Future<void> selectOutput(lk.Room? room, AudioDevice? device) async {
    _preferredOutputId = device?.id;
    if (room == null || !supportsOutputSelection) return;
    final target = device ?? await _devices.systemDefaultOutput();
    if (target == null) return;
    await room.setAudioOutputDevice(_asMediaDevice(target, 'audiooutput'));
  }

  lk.MediaDevice _asMediaDevice(AudioDevice device, String kind) =>
      lk.MediaDevice(device.id, device.label, kind, device.groupId);
}
