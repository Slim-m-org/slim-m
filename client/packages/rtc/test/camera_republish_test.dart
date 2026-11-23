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

  _Camera? camera;
  final calls = <String>[];

  @override
  lk.LocalTrackPublication? getTrackPublicationBySource(
          lk.TrackSource source) =>
      source == lk.TrackSource.camera ? camera : null;

  @override
  Future<void> removePublishedTrack(String trackSid,
      {bool notify = true}) async {
    calls.add('remove $trackSid');
    camera = null;
  }

  @override
  Future<lk.LocalTrackPublication<lk.LocalVideoTrack>> publishVideoTrack(
    lk.LocalVideoTrack track, {
    lk.VideoPublishOptions? publishOptions,
  }) async {
    calls.add('publish ${track.currentOptions.params.dimensions.height} '
        '${publishOptions?.videoEncoding?.maxBitrate}');
    return _Camera(track) as lk.LocalTrackPublication<lk.LocalVideoTrack>;
  }

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

    test('a fresh publish carries the quality\'s encoding', () async {
      for (final q in CameraQuality.values) {
        final me = _Me(null);
        await CameraSwitching(
          _NoCameras(),
          measure: (_) async => null,
          // ignore: invalid_use_of_internal_member
          createTrack: (options) async => lk.LocalVideoTrack(
            lk.TrackSource.camera,
            _Stream(),
            _Capture(),
            options,
          ),
        ).setEnabled(
          me,
          true,
          options: _options(q),
          publishOptions: cameraPublishOptionsFor(q),
        );
        expect(
          me.calls,
          [
            'publish ${q.params.dimensions.height} ${q.params.encoding!.maxBitrate}'
          ],
          reason: q.name,
        );
      }
    });

    test('a republish after a quality change carries the new encoding',
        () async {
      final me = _Me(_Camera(_publishedAt(CameraQuality.balanced)));
      final switching = CameraSwitching(
        _NoCameras(),
        measure: (_) async => null,
        createTrack: (options) async => _publishedAt(CameraQuality.high),
      );
      await switching.setEnabled(
        me,
        true,
        options: _options(CameraQuality.high),
        publishOptions: cameraPublishOptionsFor(CameraQuality.high),
      );
      expect(me.calls, ['remove TR_camera', 'publish 1080 4500000']);
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
