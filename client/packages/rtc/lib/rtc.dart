// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// LiveKit room and client wrapper behind an explicit public API.
///
/// Everything the app does with media goes through here, so nothing else in
/// the client imports livekit_client or flutter_webrtc directly. That keeps
/// the RTC dependency in one package, and means a widget test can drive a
/// session without a real SFU behind it.
library;

export 'src/android_capture_permission.dart';
export 'src/audio_device_switching.dart';
export 'src/audio_devices.dart';
export 'src/pulse_audio.dart';
export 'src/audio_event_scope.dart';
export 'src/call_media_role.dart'
    show
        applyCallMediaRole,
        callMediaRoleFlag,
        callMediaRoleRequested,
        pulsePropWithCallRole;
export 'src/audio_gain.dart';
export 'src/audio_publish_options.dart';
export 'src/screen_share_audio_options.dart';
export 'src/broadcast_bridge.dart';
export 'src/call_stats.dart';
export 'src/strong_noise_suppression.dart';
export 'src/strong_inactivity.dart';
export 'src/stream_quality_label.dart';
export 'src/call_stats_sampler.dart'
    show CallStatsSampler, CallStatsSnapshot, CallStatsTarget;
export 'src/camera_devices.dart';
export 'src/camera_failure.dart';
export 'src/camera_switching.dart';
export 'src/desktop_sources.dart';
export 'src/join_timings.dart';
export 'src/input_gate.dart'
    show
        InputGateMonitor,
        InputGateReading,
        inputLevelFraction,
        kDefaultInputThresholdDb,
        kInputFloorDb,
        kInputGateDisplayInterval,
        InputGateRate;
export 'src/local_audio.dart';
export 'src/media_capabilities.dart';
export 'src/mirror_self_view.dart';
export 'src/mic_failure.dart';
export 'src/mic_fallback.dart' show fallbackCandidates;
export 'src/os_mic_block.dart' show osBlocksMicrophone;
export 'src/mic_port.dart';
export 'src/mic_preview.dart';
export 'src/mic_preview_loopback.dart' show LoopbackMicSource, systemMicPreview;
export 'src/mic_recovery.dart';
export 'src/mic_release.dart';
export 'src/remote_video_publication.dart';
export 'src/screen_share.dart';
export 'src/screen_share_audio.dart';
export 'src/share_audio_isolation.dart';
export 'src/screen_share_control.dart';
export 'src/video_publish_options.dart';
export 'src/video_quality.dart';
export 'src/screen_share_status.dart';
export 'src/video_stall_watchdog.dart' show VideoTileHealth;
export 'src/video_subscription_culler.dart';
export 'src/voice_health.dart'
    show
        VoiceHealth,
        kPoorConcealmentShare,
        kPoorJitterBufferMs,
        kPoorRttMs,
        kPoorSustain,
        kRecoverSustain;
export 'src/voice_health_summary.dart' show CallHealthSummary, HealthStats;
export 'src/voice_health_window.dart' show HealthInterval;
export 'src/voice_models.dart';
export 'src/voice_roster_snapshot.dart'
    show
        anyLiveVideo,
        deafenedFromAttributes,
        isSpeakingNow,
        passesActivationThreshold;
export 'src/voice_session.dart';
