// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A fresh camera publish that fails must not leave the capture running: the
/// camera light would stay on after the error is reported.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _Stream extends Fake implements webrtc.MediaStream {
  @override
  Future<void> dispose() async {}
}

class _Capture extends Fake implements webrtc.MediaStreamTrack {
  int stops = 0;

  @override
  String? get id => 'capture';

  @override
  webrtc.StreamTrackCallback? onEnded;

  @override
  Future<void> stop() async => stops++;
}

class _Me extends Fake implements lk.LocalParticipant {
  @override
  lk.LocalTrackPublication? getTrackPublicationBySource(
    lk.TrackSource source,
  ) =>
      null;

  @override
  Future<lk.LocalTrackPublication<lk.LocalVideoTrack>> publishVideoTrack(
    lk.LocalVideoTrack track, {
    lk.VideoPublishOptions? publishOptions,
  }) async =>
      throw StateError('the SFU refused the track');
}

class _NoCameras implements CameraDevices {
  @override
  Future<List<CameraDevice>> list() async => const [];
}

void main() {
  test('a publish that throws stops the capture it opened', () async {
    final capture = _Capture();
    final result = await CameraSwitching(
      _NoCameras(),
      measure: (_) async => null,
      // ignore: invalid_use_of_internal_member
      createTrack: (options) async => lk.LocalVideoTrack(
          lk.TrackSource.camera, _Stream(), capture, options),
    ).setEnabled(
      _Me(),
      true,
      options: cameraCaptureOptionsFor(
        const lk.CameraCaptureOptions(),
        CameraQuality.balanced,
      ),
      publishOptions: cameraPublishOptionsFor(CameraQuality.balanced),
    );

    expect(result.ok, isFalse);
    expect(capture.stops, greaterThan(0));
  });
}
