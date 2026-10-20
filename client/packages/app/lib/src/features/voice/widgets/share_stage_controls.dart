// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that choose which screen shares a viewer watches: the stage
/// the shared context-menu rows, and the opt-back-in chip.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// The context-menu rows for one stream, shared by the share tile and the
/// participant menus; a null callback drops its row.
List<Widget> shareStageMenuItems(
  VoidCallback close, {
  required String sharerName,
  VoidCallback? onPopOut,
  VoidCallback? onStreamVolume,
  VoidCallback? onFocus,
  bool focused = false,
  VoidCallback? onStopWatching,
  VoidCallback? onFullscreen,
}) {
  Widget row(String label, IconData icon, VoidCallback act) => AppMenuItem(
    label: label,
    leading: icon,
    onTap: () {
      close();
      act();
    },
  );
  return [
    if (onPopOut != null) row('Pop out stream', AppIcons.popOut, onPopOut),
    if (onStreamVolume != null)
      row('Stream volume', AppIcons.speaker, onStreamVolume),
    if (onFocus != null)
      row(
        focused ? 'Show all shares' : "Focus $sharerName's screen",
        focused ? AppIcons.collapse : AppIcons.shareFocus,
        onFocus,
      ),
    if (onStopWatching != null)
      row('Hide stream', AppIcons.tileHide, onStopWatching),
    if (onFullscreen != null) row('Full screen', AppIcons.expand, onFullscreen),
  ];
}
