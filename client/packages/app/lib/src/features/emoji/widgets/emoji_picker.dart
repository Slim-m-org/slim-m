// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker's hover-anchored entry point: the floating surface
/// opened from the add-reaction control on a message hover, wrapping the
/// one [EmojiPickerPanel] (re-exported here so a caller needs this import
/// only).
///
/// The two touch-reachable entry points - a bottom sheet reaching the full
/// catalog, and the composer's own narrower one over just the Space's own
/// emoji - are re-exported from `emoji_picker_sheets.dart`, split out to
/// keep this file inside the review budget.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../widgets/animated_menu_portal.dart';
import 'emoji_picker_panel.dart';
import '../../../widgets/hover_reveal.dart';
import '../../messages/widgets/message_context_menu_layout.dart';
import '../../../action_labels.dart';

export 'emoji_picker_panel.dart' show EmojiPickerPanel;
export 'emoji_picker_sheets.dart'
    show showEmojiPickerSheet, showSpaceEmojiSheet;

/// The drop below the button's own bottom edge, matching the gap the old
/// `CompositedTransformFollower` offset used to leave.
const Offset _buttonDrop = Offset(0, 4);

/// The add-reaction glyph, anchored so its picker opens beneath it and
/// closes on an outside tap, an escape, or a pick.
///
/// Positioned through [MessageMenuLayout] - the same clamp
/// `ContextMenuRegion` uses - rather than a bare `CompositedTransformFollower`
/// offset, which had no notion of the viewport edge: opened from a message
/// near the right side of the transcript, the panel ran off the screen with
/// only its category rail visible. A static anchor taken at open time means
/// the panel does not track the button through a scroll the way the
/// follower did, so it closes on one instead, `ContextMenuRegion`'s own
/// answer to the same trade.
class EmojiPickerButton extends StatefulWidget {
  const EmojiPickerButton({
    super.key,
    required this.onSelect,
    this.triggerBuilder,
    this.focusNode,
  });

  final ValueChanged<String> onSelect;

  /// Lets a row that walks its own controls with the arrow keys own this stop.
  final FocusNode? focusNode;

  /// Draws something other than the toolbar glyph as the control that opens
  /// the picker; the callback toggles it. The picker still anchors under it.
  final Widget Function(BuildContext context, VoidCallback toggle)?
  triggerBuilder;

  @override
  State<EmojiPickerButton> createState() => _EmojiPickerButtonState();
}

class _EmojiPickerButtonState extends State<EmojiPickerButton> {
  final _controller = AnimatedMenuController();
  Offset _anchor = Offset.zero;
  ScrollPosition? _watched;

  @override
  void dispose() {
    _watched?.removeListener(_closeOnScroll);
    super.dispose();
  }

  /// Keeps the row that reveals this button on hover from unmounting it while
  /// the panel is open, since reaching the panel takes the pointer off the row.
  void _setOpen(bool open) {
    HoverRevealScope.maybeOf(context)?.pin(open);
    if (open) _anchor = _anchorOffset();
    _watchScroll(open);
    open ? _controller.show() : _controller.hide();
  }

  /// The button's own bottom-left corner, in the overlay's coordinate space,
  /// dropped by [_buttonDrop] - the same corner the old follower anchored to.
  Offset _anchorOffset() {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return Offset.zero;
    return box.localToGlobal(
      Offset(0, box.size.height) + _buttonDrop,
      ancestor: overlay,
    );
  }

  void _closeOnScroll() {
    if (_controller.isShowing) _setOpen(false);
  }

  void _watchScroll(bool open) {
    final position = open ? Scrollable.maybeOf(context)?.position : null;
    if (identical(position, _watched)) return;
    _watched?.removeListener(_closeOnScroll);
    _watched = position;
    _watched?.addListener(_closeOnScroll);
  }

  void _toggle() => _setOpen(!_controller.isShowing);

  void _select(String emoji) {
    _setOpen(false);
    widget.onSelect(emoji);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller.portal,
      overlayChildBuilder: (context) => Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: MessageMenuLayout(
            anchor: _anchor,
            padding:
                MediaQuery.paddingOf(context) +
                const EdgeInsets.all(menuScreenMargin),
          ),
          child: AnimatedMenuSurface(
            controller: _controller,
            child: TapRegion(
              onTapOutside: (_) => _setOpen(false),
              child: EmojiPickerPanel(
                onSelect: _select,
                onClose: () => _setOpen(false),
              ),
            ),
          ),
        ),
      ),
      child: switch (widget.triggerBuilder) {
        final build? => build(context, _toggle),
        null => AppIconButton(
          focusNode: widget.focusNode,
          icon: AppIcons.smile,
          semanticLabel: ActionLabels.addReaction,
          iconSize: AppSizes.icon16,
          onPressed: _toggle,
        ),
      },
    );
  }
}
