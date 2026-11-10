// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The collaborators of one voice session, wired to each other.
///
/// Every piece of a call is a class of its own with a narrow host; this is the
/// one place that knows how they reach each other. [VoiceSession] forwards its
/// public members here, and [VoiceCallFlow] drives the call lifecycle over it.
library;

import 'dart:async';

import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_api/api.dart' show AppLog, LogLevel, LogTag;

import 'audio_devices.dart';
import 'broadcast_bridge.dart';
import 'camera_devices.dart';
import 'camera_join.dart';
import 'desktop_sources.dart';
import 'input_gate.dart';
import 'join_timings.dart';
import 'livekit_setup_log.dart';
import 'mic_failure.dart';
import 'mic_port.dart';
import 'mic_recovery.dart';
import 'mic_release.dart';
import 'pulse_audio.dart';
import 'share_audio_isolation.dart';
import 'start_bitrate_room.dart';
import 'video_quality.dart';
import 'voice_audio_devices.dart';
import 'voice_call_flow.dart';
import 'voice_health_watch.dart';
import 'voice_input_gate.dart';
import 'voice_listener_audio.dart';
import 'voice_log.dart';
import 'voice_mic_readiness.dart';
import 'voice_mic_recovery.dart';
import 'voice_processing_control.dart';
import 'voice_roster.dart';
import 'voice_session_camera.dart';
import 'voice_session_screen_share.dart';
import 'voice_stall_wiring.dart';
import 'voice_stats_wiring.dart';
import 'voice_video_receive.dart';
import 'audio_device_switching.dart';

/// Builds the LiveKit room a session drives. The injection seam.
typedef RoomFactory = lk.Room Function();

/// Builds every collaborator of a [VoiceSession] and holds what they share.
class VoiceSessionCore {
  VoiceSessionCore({
    RoomFactory? roomFactory,
    BroadcastBridge? broadcast,
    DesktopSources? desktopSources,
    CameraDevices? cameraDevices,
    InputGateMonitor? inputGate,
    MicPort? micPort,
    VoiceLog? audioLog,
    AudioDevices? audioDevices,
    LiveOutputSwitch? liveOutput,
    LiveInputSwitch? liveInput,
    PulseAudio? pulse,
    OsMicBlockProbe? osMicBlocked,
    MicRecoveryTiming micRecoveryTiming = const MicRecoveryTiming(),
    Duration micReleaseGrace = kMicReleaseGrace,
    bool? mobile,
    JoinTimings? joinTimings,
    ShareAudioIsolation? shareAudioIsolation,
    Duration cameraJoinTimeout = kJoinCameraTimeout,
  }) : joinTimings = joinTimings ?? JoinTimings() {
    createRoom = roomFactory ?? _buildRoom;
    listener = VoiceListenerAudio(
      VoiceListenerAudioHost(
        room: () => flow.room,
        noteError: noteError,
        refresh: refresh,
      ),
    )..audio.log = audioLog;
    healthWatch = VoiceHealthWatch(
      VoiceHealthWatchHost(room: () => flow.room, diag: diag),
    );
    // An injected room has no native capture behind it to gate.
    final gate = inputGate ??
        (roomFactory == null
            ? InputGateMonitor()
            : InputGateMonitor.disabled());
    gate.setRate(InputGateRate.watch);
    mic = micPort ?? LiveKitMicPort(() => flow.room);
    devices = VoiceAudioDevices(
      VoiceAudioDevicesHost(
        room: () => flow.room,
        noteError: noteError,
        supportsInputGate: () => micGate.supported,
        applyInputGate: () => micGate.apply(),
        diag: diag,
      ),
      mic,
      devices: audioDevices,
      liveOutput: liveOutput,
      liveInput: liveInput,
      pulse: pulse,
    );
    micGate = VoiceInputGate(
      VoiceInputGateHost(
        refresh: refresh,
        diag: diag,
        reopenCapture: reopenCapture,
      ),
      gate: gate,
      mic: mic,
      switching: devices.switching,
    );
    devices.switching.levelsNatively = () => micGate.levelsNatively;
    readiness = VoiceMicReadiness(
      VoiceMicReadinessHost(
        hasRoom: () => flow.room != null,
        mic: mic,
        micWanted: () => micRecovery.micWanted,
        plainOptions: plainOpenOptions,
        joinTimings: this.joinTimings,
        diag: diag,
      ),
      grace: micReleaseGrace,
      mobile: mobile ?? lk.lkPlatformIsMobile(),
    );
    micRecovery = VoiceMicRecovery(
      VoiceMicRecoveryHost(
        room: () => flow.room,
        state: () => flow.state,
        noteError: noteError,
        refresh: refresh,
        diag: diag,
        openCaptureOptions: openCaptureOptions,
        forgetUnplugged: devices.forgetUnplugged,
        followPreferred: devices.followPreferred,
        selectInput: (device) => devices.selectInput(device, remember: false),
        selectOutput: (device) => devices.selectOutput(device, remember: false),
        micPublished: () => this.joinTimings.mark(JoinStage.micPublished),
      ),
      mic: mic,
      gate: gate,
      switching: devices.switching,
      release: readiness.release,
      timing: micRecoveryTiming,
      // An injected room has no sound stack to watch unless a test brings one.
      watchDevices: audioDevices != null || roomFactory == null,
      osMicBlocked: osMicBlocked,
    );
    share = VoiceScreenShare(
      VoiceScreenShareHost(
        room: () => flow.room,
        noteError: noteError,
        refresh: refresh,
        reported: reported,
      ),
      broadcast: broadcast ?? const MethodChannelBroadcastBridge(),
      desktopSources: desktopSources ?? const WebrtcDesktopSources(),
      isolation: shareAudioIsolation ?? ShareAudioIsolation(),
    );
    stats = VoiceStatsWiring(
      VoiceStatsWiringHost(
        room: () => flow.room,
        disposed: () => flow.disposed,
        audioInputId: () => devices.inputInUse,
        diag: diag,
      ),
      healthWatch.diagnostics,
    );
    video = VoiceVideoReceive(
      VoiceVideoReceiveHost(
        room: () => flow.room,
        disposed: () => flow.disposed,
        refresh: refresh,
        syncStall: () => stall.sync(),
        diag: diag,
      ),
    );
    stall = VoiceStallWiring(
      VoiceStallWiringHost(
        room: () => flow.room,
        disposed: () => flow.disposed,
        reconnecting: () => healthWatch.health.reconnect.restarting.value,
        receiveQuality: () => video.quality,
        diag: diag,
      ),
      sampler: stats.sampler,
      culler: video.culler,
    );
    camera = VoiceCamera(
      share.host,
      video.density,
      devices: cameraDevices,
      joinTimeout: cameraJoinTimeout,
    );
    roster = VoiceRoster(
      VoiceRosterHost(
        refresh: refresh,
        reconnecting: () => healthWatch.health.reconnect.restarting.value,
        localVoice: () => gate.fast ? gate.voice : null,
        deafened: () => listener.deafened,
      ),
    );
    flow = VoiceCallFlow(this);
  }

  final JoinTimings joinTimings;

  /// Why the last attempt failed; see [VoiceSession.lastError].
  Object? lastError;

  late final RoomFactory createRoom;
  late final VoiceCallFlow flow;
  late final VoiceListenerAudio listener;
  late final VoiceHealthWatch healthWatch;
  late final MicPort mic;
  late final VoiceAudioDevices devices;
  late final VoiceInputGate micGate;
  late final VoiceMicReadiness readiness;
  late final VoiceMicRecovery micRecovery;
  late final VoiceScreenShare share;
  late final VoiceStatsWiring stats;
  late final VoiceVideoReceive video;
  late final VoiceStallWiring stall;
  late final VoiceCamera camera;
  late final VoiceRoster roster;
  late final setupLog = LiveKitSetupLog(diag);

  late final processing = VoiceProcessingControl(
    switching: devices.switching,
    mic: mic,
    release: readiness.release,
    micWanted: () => micRecovery.micWanted,
    restartCapture: micRecovery.restartCapture,
    reopenMuted: () => mic.reopenMuted(plainOpenOptions()),
    log: diag,
  );

  /// The room a fresh call publishes into: only what is on screen is
  /// subscribed, at the size shown, so several video tiles do not cost the
  /// same as all at full size, plus whatever microphone/speaker Voice
  /// Settings has chosen; see [VoiceAudioDevices].
  lk.Room _buildRoom() => buildRoomWithStartBitrate(
        devices.switching.roomOptions(receiveRoomOptions()),
      );

  void noteError(Object error) => lastError = error;

  /// Into the app's debug log when the app wired one, so a tester's export shows it.
  void diag(String line, {LogLevel level = LogLevel.info}) =>
      (listener.audio.log ?? _appLogVoice)(line, level: level);

  static void _appLogVoice(String line, {LogLevel level = LogLevel.info}) =>
      AppLog.at(level, LogTag.voice, line);

  Future<T> reported<T>(String action, T fallback, Future<T> Function() run) =>
      runReported(action, fallback, run, noteError);

  /// What the next microphone open captures with; see [VoiceAudioDevices.openCaptureOptions].
  lk.AudioCaptureOptions openCaptureOptions({required bool reopen}) =>
      devices.openCaptureOptions(reopen: reopen);

  lk.AudioCaptureOptions plainOpenOptions() =>
      openCaptureOptions(reopen: false);

  /// Reopens the capture when it changed; echo, gain and suppression are fixed at open.
  Future<void> reopenCapture(String reason) =>
      processing.reopen(reason, inCall: flow.room != null);

  /// Brings every part of the call up to date with the live room.
  void refresh() {
    micGate.applyRate();
    final room = flow.room;
    if (room == null || flow.disposed) return;
    // Reapplied on every refresh, not only on toggle, so deafening reaches a participant or track that appears afterward too.
    unawaited(listener.apply(room));
    // Ahead of the unchanged-roster early return: a subscription can change with no visible roster change at all.
    video.applyInterest();
    unawaited(video.applyQuality(room));
    roster.update(room);
  }
}
