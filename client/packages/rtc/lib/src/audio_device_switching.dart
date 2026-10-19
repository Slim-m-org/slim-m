// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Picking a microphone or speaker, `camera_switching.dart`'s own shape for
/// audio: the room is handed in per call rather than held here, so this
/// stays a plain, test-friendly class with no LiveKit connection of its own.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'audio_devices.dart';
import 'pulse_audio.dart';
import 'voice_models.dart';

/// Points a live [lk.Room]'s capture at [device]. A seam so tests can see
/// what a mid-call pick sends without a native audio stack.
typedef LiveInputSwitch = Future<void> Function(
  lk.Room room,
  lk.MediaDevice device,
);

class AudioDeviceSwitching {
  AudioDeviceSwitching(
    this._devices, {
    LiveInputSwitch? liveInput,
    PulseAudio? pulse,
  })  : _liveInput = liveInput ?? switchLiveInput,
        _pulse = pulse ?? PulseAudio();

  final AudioDevices _devices;
  final LiveInputSwitch _liveInput;

  /// Applies a pick that came from the sound server's list rather than
  /// libwebrtc's; see `pulse_audio_io.dart`.
  final PulseAudio _pulse;

  // What the person chose, kept even while that device is unplugged.
  String? _chosenInputId;
  String? _chosenOutputId;

  // What is in use now: the choice while it is plugged in, otherwise the system default (null).
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
  lk.RoomOptions roomOptions(
    lk.RoomOptions base, {
    bool noiseSuppression = true,
  }) =>
      base.copyWith(
        defaultAudioCaptureOptions: captureOptions(
          noiseSuppression: noiseSuppression,
        ),
        defaultAudioOutputOptions: lk.AudioOutputOptions(
          deviceId:
              isPulseDeviceId(_preferredOutputId) ? null : _preferredOutputId,
        ),
      );

  /// [noiseSuppression] is libwebrtc's own; Strong turns it off where rnnoise
  /// runs instead.
  lk.AudioCaptureOptions captureOptions({bool noiseSuppression = true}) =>
      lk.AudioCaptureOptions(
        // libwebrtc cannot open a sound server node; [applyServerRouting] moves the stream instead.
        deviceId: isPulseDeviceId(_preferredInputId) ? null : _preferredInputId,
        noiseSuppression: noiseSuppression,
        // The session releases a muted capture after a grace period; reopening on every unmute flips Bluetooth profiles and clips the first syllable.
        stopAudioCaptureOnMute: false,
      );

  /// The microphone the person chose, kept while it is unplugged.
  String? get chosenInput => _chosenInputId;

  /// The microphone in use now, or null for the system default.
  String? get inputInUse => _preferredInputId;

  /// Whether the capture rides whatever the system default microphone is.
  bool get followsSystemDefaultInput => _preferredInputId == null;

  /// Changes whenever a microphone appears, goes, or becomes the system
  /// default, so a capture on the old default can be told to move.
  Future<String> inputSignature() async {
    final ids = [for (final d in await inputs()) d.id]..sort();
    final fallback = (await _devices.systemDefaultInput())?.id ??
        await _pulse.defaultNode(capture: true) ??
        '';
    return '$fallback|${ids.join(',')}';
  }

  /// [inputId] while that microphone is plugged in, otherwise null (the system
  /// default): a browser refuses an unknown id outright and a desktop engine
  /// keeps whatever it last used, so the preview must not ask for it.
  Future<String?> pluggedInputId(String? inputId) async {
    if (inputId == null) return null;
    try {
      return resolveAudioDevice(await inputs(), inputId)?.id;
    } on Object {
      return inputId;
    }
  }

  /// A capture that opens [inputId] without a call, for the level preview.
  lk.AudioCaptureOptions previewCaptureOptions(String? inputId) =>
      lk.AudioCaptureOptions(
        deviceId: isPulseDeviceId(inputId) ? null : inputId,
        stopAudioCaptureOnMute: false,
      );

  /// Moves a just-opened preview capture onto a sound-server node.
  Future<void> routePreviewInput(String? inputId) async {
    if (isPulseDeviceId(inputId)) {
      await _pulse.moveOwnStreams(capture: true, deviceId: inputId!);
    }
  }

  /// Whether the chosen microphone is absent from a list that names others.
  /// An empty list says nothing, and one read can be partial mid-change.
  Future<bool> chosenInputMissing() async {
    final chosen = _chosenInputId;
    if (chosen == null) return false;
    final listed = await inputs();
    return listed.isNotEmpty && resolveAudioDevice(listed, chosen) == null;
  }

  /// Falls back to the system default for a chosen microphone or speaker that
  /// is not plugged in, so the next [roomOptions] does not ask the browser for
  /// a device it would refuse. True when the microphone in use was the one
  /// dropped, so a live capture on it needs reopening.
  Future<bool> forgetUnpluggedPreferences() async =>
      (await reconcilePreferences(null)).inputDropped;

  /// [forgetUnpluggedPreferences], and the other way too: a chosen device that
  /// is plugged in again is used again, so a headset that blinks off Bluetooth
  /// does not leave the call on the default while Settings still shows it.
  /// A returned speaker is applied to [room] when one is given.
  Future<({bool inputDropped, bool inputRestored})> reconcilePreferences(
    lk.Room? room,
  ) async {
    final inputs = await this.inputs();
    final outputs = await this.outputs();
    // An empty list is a platform that has not enumerated yet, not an unplugged headset.
    final input = inputs.isEmpty
        ? _preferredInputId
        : resolveAudioDevice(inputs, _chosenInputId)?.id;
    final output = outputs.isEmpty
        ? _preferredOutputId
        : resolveAudioDevice(outputs, _chosenOutputId)?.id;
    final result = (
      inputDropped: _preferredInputId != null && input == null,
      inputRestored: _preferredInputId == null && input != null,
    );
    final outputRestored = _preferredOutputId == null && output != null;
    _preferredInputId = input;
    _preferredOutputId = output;
    if (outputRestored && room != null) {
      await selectOutput(room, resolveAudioDevice(outputs, output));
    }
    return result;
  }

  /// Applies [device] to [room]'s live input when one exists and this
  /// platform honours it, and remembers it either way for the next
  /// [roomOptions].
  ///
  /// Null means the system default. Mid-call, that selects the platform's
  /// own default entry, and changes nothing live where it lists none: the
  /// first physical device is not the system default.
  ///
  /// True when the live capture was reopened on the new device.
  Future<bool> selectInput(lk.Room? room, AudioDevice? device) async {
    _preferredInputId = _chosenInputId = device?.id;
    if (room == null || !supportsInputSelection) return false;
    final target = device ?? await _devices.systemDefaultInput();
    if (target == null) {
      // libwebrtc knows no default here; the sound server's own one is the system default.
      final serverDefault = await _pulse.defaultNode(capture: true);
      if (serverDefault != null) {
        await _pulse.moveOwnStreams(capture: true, deviceId: serverDefault);
      }
      return false;
    }
    if (isPulseDeviceId(target.id)) {
      await _pulse.moveOwnStreams(capture: true, deviceId: target.id);
      return false;
    }
    await _liveInput(room, _asMediaDevice(target, 'audioinput'));
    return true;
  }

  /// Re-points this process's streams at the preferred sound server nodes;
  /// a new stream (a join, a restarted capture) starts on the server default.
  Future<void> applyServerRouting() async {
    final input = _preferredInputId;
    final output = _preferredOutputId;
    if (isPulseDeviceId(input)) {
      await _pulse.moveOwnStreams(capture: true, deviceId: input!);
    }
    if (isPulseDeviceId(output)) {
      await _pulse.moveOwnStreams(capture: false, deviceId: output!);
    }
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
    _preferredOutputId = _chosenOutputId = device?.id;
    if (room == null || !supportsOutputSelection) return;
    final target = device ?? await _devices.systemDefaultOutput();
    if (target == null) {
      // libwebrtc knows no default here; the sound server's own one is the system default.
      final serverDefault = await _pulse.defaultNode(capture: false);
      if (serverDefault != null) {
        await _pulse.moveOwnStreams(capture: false, deviceId: serverDefault);
      }
      return;
    }
    if (isPulseDeviceId(target.id)) {
      await _pulse.moveOwnStreams(capture: false, deviceId: target.id);
      return;
    }
    await room.setAudioOutputDevice(_asMediaDevice(target, 'audiooutput'));
  }

  lk.MediaDevice _asMediaDevice(AudioDevice device, String kind) =>
      lk.MediaDevice(device.id, device.label, kind, device.groupId);
}
