// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Choosing which screen to share, on the desktops that make the app ask.
/// Built on `device_choice_sheet.dart`, the shape `camera_source_sheet.dart`
/// shares.
library;

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import 'device_choice_sheet.dart';

/// The line under the title; on Windows, where a window share can lose its source, it says which windows those are.
String screenSourceCaption(List<ScreenShareSource> sources, {bool? windows}) {
  const base = 'Everyone in the call will see it until you stop sharing.';
  final onWindows = windows ?? defaultTargetPlatform == TargetPlatform.windows;
  if (!onWindows || !sources.any((s) => s.isWindow)) return base;
  return '$base Minimized windows and exclusive fullscreen games cannot be '
      'captured as a window; share the screen instead.';
}

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
      title: sources.any((s) => s.isWindow)
          ? 'Share a screen or window'
          : 'Share a screen',
      caption: screenSourceCaption(sources),
      icon: AppIcons.screenShare,
      iconOf: (s) => s.isWindow ? AppIcons.windowRestore : AppIcons.screenShare,
      items: sources,
      labelOf: (source) => source.name,
      isSelected: selectedId == null ? null : (s) => s.id == selectedId,
    ),
  );
}
