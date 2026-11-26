// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which optional controls a call offers, and which of them draw in the dock
/// row rather than in its More menu.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_options_menu.dart';
import '../providers/voice_flags.dart';
import '../providers/voice_settings_controller.dart';
import 'dock_item.dart';
import 'soundboard_button.dart';
import 'soundboard_picker.dart';
import 'transcript_menu.dart';

/// Every optional control this call offers, in the order More lists them.
///
/// [extras] are the controls a caller adds (the canvas toggle, the music
/// button); [switchCamera] is the camera flip, offered only when [canSwitch].
List<DockItem> buildDockItems(
  BuildContext context,
  WidgetRef ref, {
  required VoiceFlags voice,
  required List<DockItem> extras,
  required bool canSwitch,
  required Widget switchCameraButton,
  required VoidCallback switchCamera,
}) {
  final channelId = voice.channelId;
  final showCaptions = ref.watch(
    voiceSettingsControllerProvider.select((s) => s.showCaptions),
  );
  return [
    if (canUseSoundboard(ref, channelId))
      DockItem(
        id: 'soundboard',
        name: 'Soundboard',
        inline: SoundboardButton(channelId: channelId!),
        entries: [
          ControlSubmenu(
            label: 'Soundboard',
            icon: AppIcons.soundboard,
            panel: (_, _) => SoundboardPicker(channelId: channelId),
          ),
        ],
      ),
    if (canUseCaptions(ref, channelId))
      DockItem(
        id: 'transcript',
        name: 'Transcript',
        keepInline: showCaptions,
        inline: TranscriptDockButton(menuContext: context),
        entries: [
          ControlSubmenu(
            label: 'Transcript',
            icon: AppIcons.callCaptions,
            value: showCaptions ? 'On' : null,
            panel: (_, close) => Column(
              mainAxisSize: MainAxisSize.min,
              children: transcriptMenuItems(context, ref, close),
            ),
          ),
        ],
      ),
    ...extras,
    if (canSwitch)
      DockItem(
        id: 'switch-camera',
        name: 'Switch camera',
        inline: switchCameraButton,
        entries: [
          ControlOption(
            label: 'Switch camera',
            icon: AppIcons.switchCamera,
            onSelected: switchCamera,
          ),
        ],
      ),
  ];
}

/// How [buildDockItems] divides between the dock row and the More menu.
class DockSplit {
  const DockSplit({
    required this.inline,
    required this.inMore,
    required this.pinnable,
  });

  final List<DockItem> inline;
  final List<DockItem> inMore;

  /// What the "Show in dock" list offers: everything the dock does not force in.
  final List<DockItem> pinnable;

  /// More is drawn while anything is left in it or can be pinned.
  bool get hasMore => inMore.isNotEmpty || pinnable.isNotEmpty;

  /// The optional buttons drawn in the row, More included.
  int get buttonCount => inline.length + (hasMore ? 1 : 0);
}

/// [inlineAllowed] false sends every item to More, for a row with no room beside the primary controls.
DockSplit splitDockItems(
  List<DockItem> items, {
  required List<String> pinned,
  required bool inlineAllowed,
}) {
  bool inRow(DockItem item) =>
      inlineAllowed && (item.keepInline || pinned.contains(item.id));
  return DockSplit(
    inline: [
      for (final item in items)
        if (inRow(item)) item,
    ],
    inMore: [
      for (final item in items)
        if (!inRow(item)) item,
    ],
    pinnable: [
      for (final item in items)
        if (!(inlineAllowed && item.keepInline)) item,
    ],
  );
}
