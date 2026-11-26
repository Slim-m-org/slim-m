// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Which optional controls a call offers, and which of them draw in the dock
/// row rather than in its More menu.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/control_menu_entries.dart';
import '../../../widgets/control_options_menu.dart';
import '../providers/call_captions.dart';
import '../providers/voice_flags.dart';
import 'captions_menu.dart';
import 'dock_item.dart';
import 'soundboard_button.dart';
import 'soundboard_picker.dart';

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
  final captionsOn =
      channelId != null && ref.watch(captionsOnProvider(channelId));
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
    if (channelId != null &&
        ref.watch(captionsControlProvider(channelId)) != CaptionsControl.hidden)
      DockItem(
        id: 'captions',
        name: 'Captions',
        keepInline: captionsOn,
        inline: CaptionsDockButton(menuContext: context, channelId: channelId),
        entries: switch (ref.watch(captionsControlProvider(channelId))) {
          // A submenu holding one row is a page for nothing, so that row is the More row.
          CaptionsControl.startable => [
            ControlSwitch(
              label: 'Show captions',
              value: captionsOn,
              onChanged: (_) =>
                  unawaited(askToTranscribe(context, () {}, channelId)),
            ),
          ],
          CaptionsControl.pending => [
            ControlInline((_) => CaptionsPendingRow(channelId: channelId)),
          ],
          _ => [
            ControlSubmenu(
              label: 'Captions',
              icon: AppIcons.callCaptions,
              value: captionsOn ? 'On' : null,
              panel: (_, close) => Column(
                mainAxisSize: MainAxisSize.min,
                children: captionsMenuItems(context, ref, close, channelId),
              ),
            ),
          ],
        },
      ),
    ...extras,
    if (canSwitch)
      DockItem(
        id: 'switch-camera',
        name: 'Switch camera',
        // A flip is a one-tap action on a phone; the row only keeps it when it fits.
        keepInline: AppTouchTargets.of(context),
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
    required this.items,
    required this.inMore,
    required this.pinnable,
  });

  /// Every item, current, whichever side of the split it falls on.
  final List<DockItem> items;
  final List<DockItem> inline;
  final List<DockItem> inMore;

  /// What the "Show in dock" list offers: empty when the row has no room to pin into.
  final List<DockItem> pinnable;

  /// More is drawn while anything is left in it or can be pinned.
  bool get hasMore => inMore.isNotEmpty || pinnable.isNotEmpty;

  /// The optional buttons drawn in the row, More included.
  int get buttonCount => inline.length + (hasMore ? 1 : 0);
}

/// [inlineAllowed] false sends every item to More, for a row with no room beside the primary controls.
///
/// [pinRoom] false means pinning one more item would not fit, so only items already pinned stay on the pin list.
DockSplit splitDockItems(
  List<DockItem> items, {
  required List<String> pinned,
  required bool inlineAllowed,
  bool pinRoom = true,
}) {
  bool inRow(DockItem item) =>
      inlineAllowed && (item.keepInline || pinned.contains(item.id));
  return DockSplit(
    items: items,
    inline: [
      for (final item in items)
        if (inRow(item)) item,
    ],
    inMore: [
      for (final item in items)
        if (!inRow(item)) item,
    ],
    pinnable: [
      if (inlineAllowed)
        for (final item in items)
          if (!item.keepInline && (pinRoom || pinned.contains(item.id))) item,
    ],
  );
}
