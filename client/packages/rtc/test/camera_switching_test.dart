// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [CameraSwitching.setEnabled] and the [CameraToggleResult] it
/// returns, in particular the wrapping that lets [VoiceSession.lastError]
/// keep answering with one `Object?` while still carrying a
/// [CameraFailureReason] for a caller that wants one.
///
/// Also [facingAfterSwitch] and [mirrorModeFor]: the two pieces of a mobile
/// camera flip that do not need a real `lk.LocalParticipant` to drive, which
/// [CameraSwitching.flip] itself does and cannot get one of in a test (its
/// constructor is private to livekit_client) - see `facingAfterSwitch`'s own
/// doc comment.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:livekit_client/livekit_client.dart' as lk;
import 'package:slimm_rtc/rtc.dart';

class _NoCameras implements CameraDevices {
  @override
  Future<List<CameraDevice>> list() async => const [];
}

class _Cameras implements CameraDevices {
  _Cameras(this.devices, {this.fails = false});

  final List<CameraDevice> devices;
  final bool fails;
  int listings = 0;

  @override
  Future<List<CameraDevice>> list() async {
    listings++;
    if (fails) throw StateError('enumeration failed');
    return devices;
  }
}

class _Local extends Fake implements lk.LocalParticipant {
  final enabled = <bool>[];

  @override
  Future<lk.LocalTrackPublication?> setCameraEnabled(
    bool value, {
    lk.CameraCaptureOptions? cameraCaptureOptions,
  }) async {
    enabled.add(value);
    return null;
  }
}

const _webcam = CameraDevice(id: 'cam-1', label: 'Webcam');
const _other = CameraDevice(id: 'cam-2', label: 'Other');

void main() {
  group('a chosen camera that vanished', () {
    Future<CameraToggleResult> enable(
      _Cameras cameras,
      _Local local, {
      String? chosen = 'cam-1',
    }) =>
        CameraSwitching(cameras).setEnabled(
          local,
          true,
          options: lk.CameraCaptureOptions(deviceId: chosen),
        );

    test('is reported instead of opening another camera', () async {
      final local = _Local();
      final result = await enable(_Cameras([_other]), local);

      expect(result.ok, isFalse);
      expect((result.error as CameraFailure).reason,
          CameraFailureReason.chosenCameraUnavailable);
      expect(local.enabled, isEmpty);
    });

    test('opens when the chosen camera is still listed', () async {
      final local = _Local();
      final result = await enable(_Cameras([_other, _webcam]), local);

      expect(result.ok, isTrue);
      expect(local.enabled, [true]);
    });

    test('does not block when nothing is listed', () async {
      final local = _Local();
      final result = await enable(_Cameras(const []), local);

      expect(result.ok, isTrue);
    });

    test('does not block when the listing itself fails', () async {
      final local = _Local();
      final result = await enable(_Cameras([_other], fails: true), local);

      expect(result.ok, isTrue);
    });

    test('is not checked when no camera was chosen', () async {
      final cameras = _Cameras([_other]);
      final result = await enable(cameras, _Local(), chosen: null);

      expect(result.ok, isTrue);
      expect(cameras.listings, 0);
    });

    test('is not checked when turning the camera off', () async {
      final cameras = _Cameras([_other]);
      final local = _Local();
      final result = await CameraSwitching(cameras).setEnabled(
        local,
        false,
        options: const lk.CameraCaptureOptions(deviceId: 'cam-1'),
      );

      expect(result.ok, isTrue);
      expect(cameras.listings, 0);
    });
  });

  group('CameraToggleResult', () {
    test('ok carries no cause and no reason', () {
      const result = CameraToggleResult.ok();
      expect(result.ok, isTrue);
      expect(result.error, isNull);
    });

    test('a failure with no reason reports the bare cause unwrapped', () {
      const result = CameraToggleResult.failed('boom', null);
      expect(result.ok, isFalse);
      expect(result.error, same('boom'));
    });

    test('a failure with a reason wraps the cause in a CameraFailure', () {
      const result = CameraToggleResult.failed(
        'boom',
        CameraFailureReason.permissionDenied,
      );
      final wrapped = result.error;
      expect(wrapped, isA<CameraFailure>());
      expect((wrapped as CameraFailure).cause, 'boom');
      expect(wrapped.reason, CameraFailureReason.permissionDenied);
    });
  });

  group('CameraSwitching.setEnabled', () {
    test('a null local participant is a no-op success', () async {
      final switching = CameraSwitching(_NoCameras());
      final result = await switching.setEnabled(null, true);
      expect(result.ok, isTrue);
    });
  });

  group('CameraSwitching.flip', () {
    test('a null local participant reports no flip and stays front', () async {
      final switching = CameraSwitching(_NoCameras());
      final ok = await switching.flip(null);
      expect(ok, isFalse);
      expect(switching.facing.value, CameraFacing.front);
    });
  });

  group('facingAfterSwitch', () {
    test('true means the swap landed on the front camera', () {
      expect(facingAfterSwitch(true), CameraFacing.front);
    });

    test('false means the back camera, not a failure', () {
      // isFrontCamera=false on total success; never reread as "it failed".
      expect(facingAfterSwitch(false), CameraFacing.back);
    });
  });

  group('mirrorModeFor', () {
    test('a local front camera mirrors', () {
      expect(
        mirrorModeFor(isLocal: true, facing: CameraFacing.front),
        lk.VideoViewMirrorMode.mirror,
      );
    });

    test('a local back camera does not mirror', () {
      expect(
        mirrorModeFor(isLocal: true, facing: CameraFacing.back),
        lk.VideoViewMirrorMode.off,
      );
    });

    test('a remote participant never mirrors, even facing front', () {
      // facing: front on purpose - proves isLocal alone decides this.
      expect(
        mirrorModeFor(isLocal: false, facing: CameraFacing.front),
        lk.VideoViewMirrorMode.off,
      );
    });
  });
}
