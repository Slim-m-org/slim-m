// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing which screen to share, on the desktops that make the app ask.
/// Built on `device_choice_sheet.dart`, the shape `camera_source_sheet.dart`
/// shares.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'device_choice_sheet.dart';

/// Returns the chosen source, or null if the sheet was dismissed.
///
/// [selectedId] marks whichever source is already in effect - non-null when
/// this reopens to switch source while a share is already running, so the
/// sheet shows what is live rather than looking freshly blank. It only ever
/// preselects a row; every entry, including that one, stays fully choosable.
Future<ScreenShareSource?> showScreenSourceSheet(
  BuildContext context,
  List<ScreenShareSource> sources, {
  String? selectedId,
}) {
  return showAppSheet<ScreenShareSource>(
    context,
    builder: (context) => DeviceChoiceSheet<ScreenShareSource>(
      title: 'Share a screen',
      caption: 'Everyone in the call will see it until you stop sharing.',
      icon: AppIcons.screenShare,
      items: sources,
      labelOf: (source) => source.name,
      isSelected: selectedId == null ? null : (s) => s.id == selectedId,
    ),
  );
}
