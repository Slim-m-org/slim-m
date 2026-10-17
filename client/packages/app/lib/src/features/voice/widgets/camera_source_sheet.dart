// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing which camera to publish, on the desktops (and browsers) where
/// more than one may exist. Built on `device_choice_sheet.dart`, the shape
/// `screen_source_sheet.dart` shares.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'device_choice_sheet.dart';

/// Returns the chosen device, or null if the sheet was dismissed.
Future<CameraDevice?> showCameraDeviceSheet(
  BuildContext context,
  List<CameraDevice> devices,
) {
  return showAppSheet<CameraDevice>(
    context,
    builder: (context) => DeviceChoiceSheet<CameraDevice>(
      title: 'Choose a camera',
      icon: AppIcons.camera,
      items: devices,
      labelOf: (device) => device.label,
    ),
  );
}
