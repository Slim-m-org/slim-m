// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The emoji picker's anchored entry points: the add-reaction control on a
/// message hover, and [EmojiPickerAnchor] for anything else that opens the
/// one [EmojiPickerPanel] (re-exported here so a caller needs this import
/// only), such as a message menu's Add reaction.
///
/// The two touch-reachable entry points - a bottom sheet reaching the full
/// catalog, and the composer's own narrower one over just the Space's own
/// emoji - are re-exported from `emoji_picker_sheets.dart`, split out to
/// keep this file inside the review budget.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../../../routing/breakpoints.dart';
import '../../../widgets/animated_menu_portal.dart';
import 'emoji_picker_panel.dart';
import 'emoji_picker_sheets.dart';
import '../../../widgets/hover_reveal.dart';
import '../../../widgets/message_context_menu_layout.dart';
import '../../../action_labels.dart';

export 'emoji_picker_panel.dart' show EmojiPickerPanel;
export 'emoji_picker_sheets.dart'
    show showEmojiPickerSheet, showSpaceEmojiSheet;

/// The drop below the button's own bottom edge, matching the gap the old
/// `CompositedTransformFollower` offset used to leave.
const Offset _buttonDrop = Offset(0, 4);

/// The add-reaction glyph, anchored so its picker opens beneath it (above it
/// when the window has no room below) and closes on an outside tap, an
/// escape, or a pick.
class EmojiPickerButton extends StatefulWidget {
  const EmojiPickerButton({
    super.key,
    required this.onSelect,
    this.triggerBuilder,
    this.focusNode,
    this.alignEnd = false,
  });

  /// Opens the panel with its right edge on the button's, for a button at a field's end.
  final bool alignEnd;

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
  final _picker = GlobalKey<EmojiPickerAnchorState>();

  void _toggle() {
    final picker = _picker.currentState;
    if (picker == null) return;
    picker.isOpen ? picker.close() : picker.open();
  }

  @override
  Widget build(BuildContext context) {
    return EmojiPickerAnchor(
      key: _picker,
      alignEnd: widget.alignEnd,
      onSelect: widget.onSelect,
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

/// Hosts the picker for whatever opens it, a button or a context menu: a
/// bottom sheet at compact width, else a panel anchored beside the opener.
///
/// Positioned through [MessageMenuLayout], the same clamp `ContextMenuRegion`
/// uses, so a panel opened near the window's edge stays on screen. The anchor
/// is taken at open time and the panel closes on a scroll rather than
/// tracking it, `ContextMenuRegion`'s own answer to the same trade.
class EmojiPickerAnchor extends StatefulWidget {
  const EmojiPickerAnchor({
    super.key,
    required this.onSelect,
    required this.child,
    this.alignEnd = false,
  });

  final bool alignEnd;
  final ValueChanged<String> onSelect;
  final Widget child;

  @override
  State<EmojiPickerAnchor> createState() => EmojiPickerAnchorState();
}

class EmojiPickerAnchorState extends State<EmojiPickerAnchor> {
  final _controller = AnimatedMenuController();
  Offset _anchor = Offset.zero;

  /// The child's top edge, when the panel hangs from the child rather than a point.
  double? _flipAbove;
  ScrollPosition? _watched;

  bool get isOpen => _controller.isShowing;

  @override
  void dispose() {
    _watched?.removeListener(_closeOnScroll);
    super.dispose();
  }

  /// Opens at [at], in the overlay's coordinates, or under [EmojiPickerAnchor.child].
  void open({Offset? at}) {
    if (LayoutClass.of(context) == LayoutClass.compact) {
      unawaited(showEmojiPickerSheet(context, onSelect: widget.onSelect));
      return;
    }
    final child = at == null ? _childEdges() : null;
    _anchor = at ?? child?.below ?? Offset.zero;
    _flipAbove = child?.above;
    _setOpen(true);
  }

  void close() => _setOpen(false);

  /// Keeps the row that reveals the opener on hover from unmounting it while
  /// the panel is open, since reaching the panel takes the pointer off the row.
  void _setOpen(bool open) {
    if (!open && !_controller.isShowing) return;
    HoverRevealScope.maybeOf(context)?.pin(open);
    _watchScroll(open);
    open ? _controller.show() : _controller.hide();
  }

  /// Where the panel hangs under the child, and the line it rises to above
  /// the child when there is no room below, both [_buttonDrop] clear of it.
  ({Offset below, double above})? _childEdges() {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final box = context.findRenderObject() as RenderBox?;
    if (overlay == null || box == null) return null;
    final x = widget.alignEnd ? box.size.width : 0.0;
    Offset global(Offset local) => box.localToGlobal(local, ancestor: overlay);
    return (
      below: global(Offset(x, box.size.height) + _buttonDrop),
      above: global(Offset(x, 0) - _buttonDrop).dy,
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
            alignEnd: widget.alignEnd,
            flipAbove: _flipAbove,
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
      child: widget.child,
    );
  }
}
