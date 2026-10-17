// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Dragging across message text to select part of it, on the platforms where
/// that gesture is not already spoken for.
///
/// Copying a whole message has always been in the context menu. What was
/// missing is selecting *within* one, or across two, which is the only way to
/// quote a sentence out of a paragraph.
///
/// **Touch platforms are deliberately excluded, and that is the whole design
/// of this file.** A long press on a phone raises the message action sheet,
/// which the owner asked for specifically and which shipped in 0.18.0.
/// `SelectionArea` claims that same gesture for selection, so enabling it
/// everywhere would trade a feature somebody asked for against one nobody
/// did. On desktop the context menu is on right-click, so the press gesture
/// is genuinely free.
///
/// The platform is the right question rather than the window width: a narrow
/// desktop window still has a mouse, and a tablet in a wide layout still has
/// no right button.
///
/// A right-click also raises [SelectionArea]'s own platform text-selection
/// menu, independently of `ContextMenuRegion`'s `onSecondaryTapUp` -
/// reported directly by the owner as two popups at once, our own menu with a
/// stray "Select all" drawn over it. [_suppressedContextMenu] answers that
/// menu with nothing, since `MessageContextMenuRegion` (which already carries
/// a "Copy text" item wired to the clipboard directly, not to this toolbar)
/// is the one menu a right-click on a message should open.
library;

import 'package:flutter/material.dart';

/// True where a press-and-drag is not already the context-menu gesture.
bool supportsTextSelection(TargetPlatform platform) =>
    platform != TargetPlatform.iOS && platform != TargetPlatform.android;

/// Built in place of [SelectionArea]'s own toolbar; selection itself is
/// unaffected, only the popup announcing it.
Widget _suppressedContextMenu(BuildContext context, SelectableRegionState _) =>
    const SizedBox.shrink();

/// Wraps [child] in a [SelectionArea] on the platforms that can take one, and
/// returns it untouched on the platforms that cannot.
class TranscriptSelection extends StatelessWidget {
  const TranscriptSelection({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!supportsTextSelection(Theme.of(context).platform)) return child;
    return SelectionArea(
      contextMenuBuilder: _suppressedContextMenu,
      child: child,
    );
  }
}
