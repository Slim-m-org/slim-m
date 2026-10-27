// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which microphone to try when the one in use has gone silent for good.
library;

import 'voice_models.dart';

/// Label fragments of software devices; they die with their driver, so real hardware goes first.
const kVirtualMicMarkers = ['sonar', 'virtual'];

bool isVirtualMic(String label) {
  final lower = label.toLowerCase();
  return kVirtualMicMarkers.any(lower.contains);
}

/// The key a candidate is remembered by; the system default has no id.
String fallbackKey(String? id) => id ?? '';

/// Microphones to try in order; a null entry is the system default.
///
/// The default comes first unless the capture already follows it, then the
/// other listed microphones with real hardware ahead of virtual ones.
/// Anything in [tried] is skipped, so a call never retries a device.
List<AudioDevice?> fallbackCandidates({
  required List<AudioDevice> inputs,
  required String? inUseId,
  required Set<String> tried,
}) {
  final others = [
    for (final d in inputs)
      if (d.id != inUseId && !tried.contains(fallbackKey(d.id))) d,
  ];
  final hardware = others.where((d) => !isVirtualMic(d.label));
  final virtual = others.where((d) => isVirtualMic(d.label));
  return [
    if (inUseId != null && !tried.contains(fallbackKey(null))) null,
    ...hardware,
    ...virtual,
  ];
}

/// One log-safe description of a device: its label, never its id.
String describeDevice(AudioDevice? device, {required bool followsDefault}) {
  final name = device == null
      ? 'unknown'
      : '"${device.label.isEmpty ? 'unnamed' : device.label}"';
  return '$name${followsDefault ? ', follows system default' : ''}';
}
