// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing which speaker to use, in-call. Built on
/// `device_choice_sheet.dart`, the same shape `camera_source_sheet.dart` and
/// `screen_source_sheet.dart` share.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'device_choice_sheet.dart';

/// Stands in for "system default" in the sheet's own item list: a real,
/// distinct value rather than Dart's own null, which `Navigator.pop(null)`
/// cannot be told apart from the sheet being dismissed with nothing chosen.
/// Mirrors `audio_device_section.dart`'s own sentinel for the same reason.
const _systemDefault = AudioDevice(id: '', label: 'System default');

/// Whether [chosen], a [showAudioOutputSheet] result, means the system
/// default rather than a real device.
bool isSystemDefaultAudioDevice(AudioDevice chosen) =>
    chosen.id == _systemDefault.id;

/// Returns the chosen device ([isSystemDefaultAudioDevice] true for the
/// system default row), or null if the sheet was dismissed with no choice.
Future<AudioDevice?> showAudioOutputSheet(
  BuildContext context,
  List<AudioDevice> devices, {
  required String? selectedId,
}) {
  return showAppSheet<AudioDevice>(
    context,
    builder: (context) => DeviceChoiceSheet<AudioDevice>(
      title: 'Choose a speaker',
      icon: AppIcons.speaker,
      items: [_systemDefault, ...devices],
      labelOf: (device) => isSystemDefaultAudioDevice(device)
          ? device.label
          : (device.label.isEmpty ? 'Unnamed device' : device.label),
      isSelected: (device) => device.id == (selectedId ?? _systemDefault.id),
    ),
  );
}
