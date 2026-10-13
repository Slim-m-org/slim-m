// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What each quality choice asks LiveKit for, with no room involved.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

RemoteVideoQualityRef _pub(
  lk.TrackSource source,
  List<lk.VideoQuality> asked, {
  bool subscribed = true,
}) =>
    (
      source: source,
      subscribed: subscribed,
      setQuality: (q) async => asked.add(q),
    );

void main() {
  group('applyReceiveVideoQuality', () {
    test('data saver caps a camera low and a share medium', () async {
      final camera = <lk.VideoQuality>[];
      final share = <lk.VideoQuality>[];
      await applyReceiveVideoQuality([
        _pub(lk.TrackSource.camera, camera),
        _pub(lk.TrackSource.screenShareVideo, share),
      ], ReceiveVideoQuality.dataSaver);
      expect(camera, [lk.VideoQuality.LOW]);
      expect(share, [lk.VideoQuality.MEDIUM]);
    });

    test('balanced caps a camera medium and leaves a share full', () async {
      final camera = <lk.VideoQuality>[];
      final share = <lk.VideoQuality>[];
      await applyReceiveVideoQuality([
        _pub(lk.TrackSource.camera, camera),
        _pub(lk.TrackSource.screenShareVideo, share),
      ], ReceiveVideoQuality.balanced);
      expect(camera, [lk.VideoQuality.MEDIUM]);
      expect(share, [lk.VideoQuality.HIGH]);
    });

    test('auto lifts any earlier cap back to the top layer', () async {
      final camera = <lk.VideoQuality>[];
      await applyReceiveVideoQuality([
        _pub(lk.TrackSource.camera, camera),
      ], ReceiveVideoQuality.auto);
      expect(camera, [lk.VideoQuality.HIGH]);
    });

    test('skips unsubscribed publications and audio sources', () async {
      final asked = <lk.VideoQuality>[];
      await applyReceiveVideoQuality([
        _pub(lk.TrackSource.camera, asked, subscribed: false),
        _pub(lk.TrackSource.microphone, asked),
        _pub(lk.TrackSource.unknown, asked),
      ], ReceiveVideoQuality.dataSaver);
      expect(asked, isEmpty);
    });
  });

  group('cameraCaptureOptionsFor', () {
    test('changes the resolution and keeps the chosen device', () {
      const base = lk.CameraCaptureOptions(deviceId: 'cam-2');
      final options = cameraCaptureOptionsFor(base, CameraQuality.high);
      expect(options.deviceId, 'cam-2');
      expect(options.params.dimensions.height, 1080);
    });

    test('balanced is the 720p a camera published before the setting', () {
      final options = cameraCaptureOptionsFor(
        const lk.CameraCaptureOptions(),
        CameraQuality.balanced,
      );
      expect(options.params, const lk.CameraCaptureOptions().params);
    });

    test('data saver publishes 360p', () {
      final options = cameraCaptureOptionsFor(
        const lk.CameraCaptureOptions(),
        CameraQuality.dataSaver,
      );
      expect(options.params.dimensions.height, 360);
    });
  });
}
