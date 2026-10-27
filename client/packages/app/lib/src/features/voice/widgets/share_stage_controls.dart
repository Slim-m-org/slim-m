// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The controls that choose which screen shares a viewer watches: the stage
/// the shared context-menu rows, and the opt-back-in chip.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';

import '../providers/voice_controller.dart';
import 'participant_audio_controls.dart';

/// The rows one stream's context menu can offer; a null callback drops its row.
class ShareStageMenu {
  const ShareStageMenu({
    required this.sharerName,
    this.onPopOut,
    this.streamVolume,
    this.quality,
    this.onFocus,
    this.focused = false,
    this.onStopWatching,
    this.onFullscreen,
  });

  final String sharerName;
  final VoidCallback? onPopOut;

  /// The slider itself, so volume is one drag in the menu and not a second click.
  final Widget? streamVolume;

  /// The read-only received-quality row, for a stream we are watching.
  final Widget? quality;
  final VoidCallback? onFocus;
  final bool focused;
  final VoidCallback? onStopWatching;
  final VoidCallback? onFullscreen;
}

/// The context-menu rows for one stream, shared by the share tile and the
/// participant menus.
List<Widget> shareStageMenuItems(VoidCallback close, ShareStageMenu menu) {
  final ShareStageMenu(
    :sharerName,
    :onPopOut,
    :streamVolume,
    :quality,
    :onFocus,
    :focused,
    :onStopWatching,
    :onFullscreen,
  ) = menu;
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
    if (streamVolume != null) streamVolume,
    if (quality != null) quality,
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

/// A person's screen volume as an inline slider row, so changing it is one drag in the menu.
Widget streamVolumeSlider(
  String identity,
  VoiceController controller, {
  bool autofocus = true,
}) => ParticipantVolumeControl(
  identity: identity,
  controller: controller,
  channel: LocalAudioChannel.screen,
  label: 'Stream volume',
  autofocus: autofocus,
);
