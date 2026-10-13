// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// LiveKit room and client wrapper behind an explicit public API.
///
/// Everything the app does with media goes through here, so nothing else in
/// the client imports livekit_client or flutter_webrtc directly. That keeps
/// the RTC dependency in one package, and means a widget test can drive a
/// session without a real SFU behind it.
library;

export 'src/audio_device_switching.dart';
export 'src/audio_devices.dart';
export 'src/audio_gain.dart';
export 'src/broadcast_bridge.dart';
export 'src/camera_devices.dart';
export 'src/camera_failure.dart';
export 'src/camera_switching.dart';
export 'src/desktop_sources.dart';
export 'src/local_audio.dart';
export 'src/media_capabilities.dart';
export 'src/remote_video_publication.dart';
export 'src/screen_share.dart';
export 'src/screen_share_audio.dart';
export 'src/screen_share_control.dart';
export 'src/video_quality.dart';
export 'src/video_subscription_culler.dart';
export 'src/voice_models.dart';
export 'src/voice_roster_snapshot.dart'
    show anyLiveVideo, passesActivationThreshold;
export 'src/voice_session.dart';
