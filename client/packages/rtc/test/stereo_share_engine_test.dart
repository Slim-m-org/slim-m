// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_models.pb.dart' as lk_models;
// ignore: implementation_imports
import 'package:livekit_client/src/proto/livekit_rtc.pb.dart' as lk_rtc;
import 'package:slimm_rtc/src/start_bitrate_room.dart';
import 'package:slimm_rtc/src/stereo_share_engine.dart';

lk_rtc.AddTrackRequest _request(lk_models.TrackSource source) =>
    lk_rtc.AddTrackRequest(
      cid: 'c',
      type: lk_models.TrackType.AUDIO,
      source: source,
    );

void main() {
  test('every call room runs on the stereo-declaring engine', () {
    final room = buildRoomWithStartBitrate(const lk.RoomOptions());
    // ignore: invalid_use_of_internal_member
    expect(room.engine, isA<StereoShareEngine>());
  });

  test('a screen share audio track is declared stereo', () {
    final req = _request(lk_models.TrackSource.SCREEN_SHARE_AUDIO);
    markShareAudioStereo(req);
    expect(req.audioFeatures, [lk_models.AudioTrackFeature.TF_STEREO]);
  });

  test('declaring it twice adds it once', () {
    final req = _request(lk_models.TrackSource.SCREEN_SHARE_AUDIO);
    markShareAudioStereo(req);
    markShareAudioStereo(req);
    expect(req.audioFeatures, hasLength(1));
  });

  test('the microphone stays mono', () {
    final req = _request(lk_models.TrackSource.MICROPHONE)
      ..audioFeatures.add(lk_models.AudioTrackFeature.TF_NO_DTX);
    markShareAudioStereo(req);
    expect(req.audioFeatures, [lk_models.AudioTrackFeature.TF_NO_DTX]);
  });

  test('shared audio is published at the stereo music bitrate', () {
    expect(
      lk.AudioEncoding.presetMusicHighQualityStereo.maxBitrate,
      128000,
    );
  });
}
