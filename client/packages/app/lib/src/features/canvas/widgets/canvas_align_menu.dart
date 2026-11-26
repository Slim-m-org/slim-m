// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Align and Distribute items for objects picked together, shared by the selection bar and the group's context menu.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

String _label(CanvasAlign mode) => switch (mode) {
  CanvasAlign.left => 'Align left',
  CanvasAlign.centre => 'Align centre',
  CanvasAlign.right => 'Align right',
  CanvasAlign.top => 'Align top',
  CanvasAlign.middle => 'Align middle',
  CanvasAlign.bottom => 'Align bottom',
  CanvasAlign.distributeHorizontally => 'Distribute horizontally',
  CanvasAlign.distributeVertically => 'Distribute vertically',
};

IconData _icon(CanvasAlign mode) => switch (mode) {
  CanvasAlign.left => AppIcons.alignLeft,
  CanvasAlign.centre => AppIcons.alignCentre,
  CanvasAlign.right => AppIcons.alignRight,
  CanvasAlign.top => AppIcons.alignTop,
  CanvasAlign.middle => AppIcons.alignMiddle,
  CanvasAlign.bottom => AppIcons.alignBottom,
  CanvasAlign.distributeHorizontally => AppIcons.distributeHorizontally,
  CanvasAlign.distributeVertically => AppIcons.distributeVertically,
};

/// One item per [CanvasAlign]; a distribute waits for a third object. [close] runs before [onAlign].
List<Widget> canvasAlignItems({
  required int count,
  required ValueChanged<CanvasAlign> onAlign,
  required VoidCallback close,
}) => [
  for (final mode in CanvasAlign.values)
    AppMenuItem(
      label: _label(mode),
      leading: _icon(mode),
      onTap: count < mode.minimumCount
          ? null
          : () {
              close();
              onAlign(mode);
            },
    ),
];

/// The context menu over objects picked together: align and distribute, then Delete.
Widget canvasGroupMenu({
  required int count,
  required bool mayDelete,
  required ValueChanged<CanvasAlign> onAlign,
  required VoidCallback onDelete,
  required VoidCallback close,
}) => AppMenu(
  width: 220,
  children: [
    ...canvasAlignItems(count: count, onAlign: onAlign, close: close),
    const AppMenuDivider(),
    AppMenuItem(
      label: 'Delete',
      leading: AppIcons.delete,
      tone: AppMenuItemTone.danger,
      onTap: mayDelete
          ? () {
              close();
              onDelete();
            }
          : null,
    ),
  ],
);
