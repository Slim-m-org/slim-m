// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Enumerating the cameras a desktop offers, for the picker several webcams
/// makes necessary.
///
/// Mobile never calls this: the OS owns which camera answers "the camera",
/// and flipping it is `Helper.switchCamera`'s job (see `VoiceSession.flipCamera`),
/// not a list to choose from.
library;

import 'package:livekit_client/livekit_client.dart' as lk;

import 'voice_models.dart';

/// The seam. The default implementation asks the platform's own device
/// list; a test supplies its own.
abstract class CameraDevices {
  Future<List<CameraDevice>> list();
}

class HardwareCameraDevices implements CameraDevices {
  const HardwareCameraDevices();

  @override
  Future<List<CameraDevice>> list() async {
    final devices = await lk.Hardware.instance.videoInputs();
    return [
      for (final device in devices)
        CameraDevice(
          id: device.deviceId,
          label: device.label,
          groupId: device.groupId,
        ),
    ];
  }
}

/// Collapses [devices] down to one entry per physical camera.
///
/// Several UVC webcams - the owner's EMEET C960 among them - expose more
/// than one V4L2 capture node for a single physical device, and the desktop
/// backend lists every node. [CameraDevice.groupId] is the strongest signal
/// where a platform sets one; the desktop backend never does, so nodes that
/// share a label and a node-independent id (the id minus a trailing
/// `video<N>` or `index<N>` node suffix) are one camera.
///
/// Two cameras of one model share a label but have different ids (their bus
/// path or serial differs), so both stay, and [_withDistinctLabels] numbers
/// the repeats so the picker can tell them apart. A blank label is never
/// grouped on its own: it is kept on its [CameraDevice.id].
List<CameraDevice> dedupeCameraDevices(List<CameraDevice> devices) {
  final seenKeys = <String>{};
  return _withDistinctLabels([
    for (final device in devices)
      if (seenKeys.add(_dedupeKey(device))) device,
  ]);
}

String _dedupeKey(CameraDevice device) {
  final groupId = device.groupId;
  if (groupId != null && groupId.isNotEmpty) return 'group:$groupId';
  if (device.label.isNotEmpty) {
    return 'label:${device.label}|${_withoutNodeSuffix(device.id)}';
  }
  return 'id:${device.id}';
}

final _nodeSuffix = RegExp(r'(video|index)\d+$', caseSensitive: false);

String _withoutNodeSuffix(String id) => id.replaceFirst(_nodeSuffix, '');

List<CameraDevice> _withDistinctLabels(List<CameraDevice> devices) {
  final totals = <String, int>{};
  for (final device in devices) {
    totals.update(device.label, (n) => n + 1, ifAbsent: () => 1);
  }
  final seen = <String, int>{};
  return [
    for (final device in devices)
      if ((totals[device.label] ?? 0) > 1 && device.label.isNotEmpty)
        CameraDevice(
          id: device.id,
          label:
              '${device.label} (${seen.update(device.label, (n) => n + 1, ifAbsent: () => 1)})',
          groupId: device.groupId,
        )
      else
        device,
  ];
}
