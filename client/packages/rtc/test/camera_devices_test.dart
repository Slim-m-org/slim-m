// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests for [dedupeCameraDevices], the fix for a switch-camera control that
/// offered a choice between devices that were really one physical webcam.
///
/// The EMEET C960 the owner reported this against enumerates more than one
/// V4L2 capture node for its single sensor; see `camera_devices.dart`'s own
/// doc comment for why [CameraDevice.groupId] is unusable for that case on
/// this app's desktop backend, and [CameraDevice.label] is used instead.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

class _FixedCameraDevices implements CameraDevices {
  _FixedCameraDevices(this._devices);

  final List<CameraDevice> _devices;

  @override
  Future<List<CameraDevice>> list() async => _devices;
}

void main() {
  group('dedupeCameraDevices', () {
    test('keeps every device when labels and ids are all distinct', () {
      const devices = [
        CameraDevice(id: 'cam-1', label: 'Built-in webcam'),
        CameraDevice(id: 'cam-2', label: 'USB webcam'),
      ];

      expect(dedupeCameraDevices(devices), devices);
    });

    test('collapses several V4L2 nodes that share one label', () {
      const devices = [
        CameraDevice(id: '/dev/video0', label: 'EMEET C960: EMEET C960'),
        CameraDevice(id: '/dev/video1', label: 'EMEET C960: EMEET C960'),
        CameraDevice(id: '/dev/video2', label: 'EMEET C960: EMEET C960'),
      ];

      final deduped = dedupeCameraDevices(devices);

      expect(deduped, hasLength(1));
      expect(deduped.single.id, '/dev/video0');
    });

    test('keeps two identical cameras on different buses, numbered apart', () {
      const devices = [
        CameraDevice(id: 'usb-0000:00:14.0-2', label: 'Logi C960'),
        CameraDevice(id: 'usb-0000:00:14.0-3', label: 'Logi C960'),
      ];

      final deduped = dedupeCameraDevices(devices);

      expect(deduped.map((d) => d.id),
          ['usb-0000:00:14.0-2', 'usb-0000:00:14.0-3']);
      expect(deduped.map((d) => d.label), ['Logi C960 (1)', 'Logi C960 (2)']);
    });

    test('collapses the nodes of each of two identical cameras separately', () {
      const devices = [
        CameraDevice(id: 'usb-1/video0', label: 'Cam'),
        CameraDevice(id: 'usb-1/video1', label: 'Cam'),
        CameraDevice(id: 'usb-2/video2', label: 'Cam'),
        CameraDevice(id: 'usb-2/video3', label: 'Cam'),
      ];

      expect(dedupeCameraDevices(devices).map((d) => d.id),
          ['usb-1/video0', 'usb-2/video2']);
    });

    test('collapses devices that share a reported groupId', () {
      const devices = [
        CameraDevice(id: 'cam-1', label: 'Front', groupId: 'group-a'),
        CameraDevice(id: 'cam-2', label: 'Front (wide)', groupId: 'group-a'),
      ];

      expect(dedupeCameraDevices(devices), hasLength(1));
    });

    test('a groupId is trusted over a coincidentally shared label', () {
      const devices = [
        CameraDevice(id: 'cam-1', label: 'Webcam', groupId: 'group-a'),
        CameraDevice(id: 'cam-2', label: 'Webcam', groupId: 'group-b'),
      ];

      // Same label, but the platform says these are two different devices.
      expect(dedupeCameraDevices(devices), hasLength(2));
    });

    test(
      'never collapses blank-labelled devices with no groupId: that would '
      'hide a real second camera rather than one duplicate node',
      () {
        const devices = [
          CameraDevice(id: 'cam-1', label: ''),
          CameraDevice(id: 'cam-2', label: ''),
        ];

        expect(dedupeCameraDevices(devices), hasLength(2));
      },
    );

    test('an empty list stays empty', () {
      expect(dedupeCameraDevices(const []), isEmpty);
    });
  });

  group('CameraSwitching.devices', () {
    test('deduplicates whatever the platform enumerates', () async {
      final switching = CameraSwitching(
        _FixedCameraDevices(const [
          CameraDevice(id: '/dev/video0', label: 'One Camera'),
          CameraDevice(id: '/dev/video1', label: 'One Camera'),
        ]),
      );

      expect(await switching.devices(), hasLength(1));
    });
  });
}
