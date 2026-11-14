// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// An engine that tells the server a screen share's audio is stereo.
///
/// livekit_client 2.13.1 never sets the stereo audio feature, and the server only
/// negotiates `stereo=1` for a track that carries it, so shared audio reached
/// viewers as mono however it was captured.
library;

import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/core/engine.dart' as lk_engine;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;

/// Marks [req] as stereo when it adds a screen share's audio; the microphone stays mono.
void markShareAudioStereo(lk_rtc.AddTrackRequest req) {
  if (req.source != lk_models.TrackSource.SCREEN_SHARE_AUDIO) return;
  if (req.audioFeatures.contains(lk_models.AudioTrackFeature.TF_STEREO)) return;
  req.audioFeatures.add(lk_models.AudioTrackFeature.TF_STEREO);
}

class StereoShareEngine extends lk_engine.Engine {
  StereoShareEngine({
    required super.roomOptions,
    super.peerConnectionCreate,
  }) : super(connectOptions: const lk.ConnectOptions());

  @override
  Future<lk_models.TrackInfo> addTrack(lk_rtc.AddTrackRequest req) {
    markShareAudioStereo(req);
    // ignore: invalid_use_of_internal_member
    return super.addTrack(req);
  }
}
