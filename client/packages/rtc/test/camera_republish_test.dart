// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A camera quality change only reaches the SFU by unpublishing the camera:
/// a muted publication unmutes with the capture options and simulcast layers
/// it was first published with.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Stream extends Fake implements webrtc.MediaStream {}

class _Capture extends Fake implements webrtc.MediaStreamTrack {
  @override
  webrtc.StreamTrackCallback? onEnded;
}

class _Camera extends Fake implements lk.LocalTrackPublication<lk.LocalTrack> {
  _Camera(this.track);

  @override
  final lk.LocalTrack track;

  @override
  String get sid => 'TR_camera';
}

class _Me extends Fake implements lk.LocalParticipant {
  _Me(this.camera);

  final _Camera? camera;
  final calls = <String>[];

  @override
  lk.LocalTrackPublication? getTrackPublicationBySource(
          lk.TrackSource source) =>
      source == lk.TrackSource.camera ? camera : null;

  @override
  Future<void> removePublishedTrack(String trackSid,
          {bool notify = true}) async =>
      calls.add('remove $trackSid');

  @override
  Future<lk.LocalTrackPublication?> setCameraEnabled(
    bool enabled, {
    lk.CameraCaptureOptions? cameraCaptureOptions,
  }) async {
    calls.add(
        'enable $enabled ${cameraCaptureOptions?.params.dimensions.height}');
    return null;
  }
}

class _NoCameras implements CameraDevices {
  @override
  Future<List<CameraDevice>> list() async => const [];
}

lk.CameraCaptureOptions _options(CameraQuality quality) =>
    cameraCaptureOptionsFor(const lk.CameraCaptureOptions(), quality);

/// The only way to get a real track without a native camera is its constructor.
// ignore: invalid_use_of_internal_member
lk.LocalVideoTrack _publishedAt(CameraQuality quality) => lk.LocalVideoTrack(
      lk.TrackSource.camera,
      _Stream(),
      _Capture(),
      _options(quality),
    );

void main() {
  group('cameraNeedsRepublish', () {
    test('a different quality than the published one needs a republish', () {
      final track = _publishedAt(CameraQuality.balanced);
      expect(
        cameraNeedsRepublish(track, _options(CameraQuality.dataSaver)),
        isTrue,
      );
      expect(
        cameraNeedsRepublish(track, _options(CameraQuality.high)),
        isTrue,
      );
    });

    test('the same quality keeps the track', () {
      final track = _publishedAt(CameraQuality.balanced);
      expect(
        cameraNeedsRepublish(track, _options(CameraQuality.balanced)),
        isFalse,
      );
    });

    test('a different device at the same quality keeps the track', () {
      final track = _publishedAt(CameraQuality.balanced);
      final other =
          _options(CameraQuality.balanced).copyWith(deviceId: 'other-camera');
      expect(cameraNeedsRepublish(track, other), isFalse);
    });

    test('no published track or no wanted options never republishes', () {
      expect(cameraNeedsRepublish(null, _options(CameraQuality.high)), isFalse);
      expect(
        cameraNeedsRepublish(_publishedAt(CameraQuality.high), null),
        isFalse,
      );
    });
  });

  group('CameraSwitching.setEnabled', () {
    test('unpublishes then republishes at the new quality', () async {
      final me = _Me(_Camera(_publishedAt(CameraQuality.balanced)));
      final result =
          await CameraSwitching(_NoCameras(), measure: (_) async => null)
              .setEnabled(
        me,
        true,
        options: _options(CameraQuality.dataSaver),
      );

      expect(result.ok, isTrue);
      expect(me.calls, ['remove TR_camera', 'enable true 360']);
    });

    test('a plain toggle at the same quality only unmutes', () async {
      final me = _Me(_Camera(_publishedAt(CameraQuality.balanced)));
      await CameraSwitching(_NoCameras(), measure: (_) async => null)
          .setEnabled(
        me,
        true,
        options: _options(CameraQuality.balanced),
      );

      expect(me.calls, ['enable true 720']);
    });

    test('turning off never unpublishes', () async {
      final me = _Me(_Camera(_publishedAt(CameraQuality.balanced)));
      await CameraSwitching(_NoCameras(), measure: (_) async => null)
          .setEnabled(
        me,
        false,
        options: _options(CameraQuality.dataSaver),
      );

      expect(me.calls, ['enable false 360']);
    });

    test('a first publish has nothing to remove', () async {
      final me = _Me(null);
      await CameraSwitching(_NoCameras(), measure: (_) async => null)
          .setEnabled(
        me,
        true,
        options: _options(CameraQuality.high),
      );

      expect(me.calls, ['enable true 1080']);
    });
  });
}
