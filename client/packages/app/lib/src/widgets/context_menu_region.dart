// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The generic mechanism behind every right-click/long-press menu in the
/// app: the gesture, where it lands, the compact-sheet/wide-floating split,
/// and the keyboard route into it.
///
/// `MessageContextMenuRegion` wraps this rather than each keeping its own
/// copy - the exact shape report and block used to take, once per subject,
/// before both were collapsed into `safety_actions.dart`'s one implementation.
///
/// `ownsFocusNode: false` (an already-focusable child, an `AppListRow`)
/// deliberately publishes no screen-reader long-press action of its own,
/// unlike the message region. The first attempt used `MergeSemantics` to fold
/// the gesture's action into the row's own node, matching the message row's
/// shape; that silently swallowed a trailing kebab's own, separate tap
/// action, since `MergeSemantics` folds every descendant into one node
/// regardless of its own boundaries. `excludeFromSemantics` is used instead:
/// the row keeps exactly the semantics it already had, and a screen-reader
/// user reaches the menu through a connected keyboard's context-menu key
/// instead, which still works unaffected. See
/// `context_menu_region_reachability_test.dart`.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

import '../routing/breakpoints.dart';
import 'animated_menu_portal.dart';
import 'context_menu_focus.dart';
import 'floating_dock_card.dart';
import 'message_context_menu_layout.dart';

/// Where the menu's top-left sits relative to the row's own top-left, used
/// only when nothing opened the menu with a pointer position at all - the
/// context-menu key, which carries no location to anchor to.
const Offset _rowInset = Offset(12, 12);

/// Nudges the menu's top-left off the exact pointer position that opened it,
/// so the cursor itself does not sit on top of the first item's hit box.
const Offset _pointerInset = Offset(4, 4);

/// Wraps [child] so a right-click or long-press over it opens a menu built by
/// [itemsBuilder], anchored under the pointer on a wide layout or presented
/// as a bottom sheet on a compact one.
///
/// The right-click is taken on `onSecondaryTapUp`, not `onSecondaryTapDown`.
/// Regions nest - a DM row inside the rail, which has a menu of its own - and
/// Flutter fires every nested recognizer's *down* callback once the press
/// deadline passes, whether or not the gesture arena has picked a winner. So
/// both menus opened at once, the rail's "Create channel" drawn over the
/// row's own items. The up callback is only ever delivered to the arena's
/// winner, which for nested taps is the innermost region.
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({
    super.key,
    required this.itemsBuilder,
    required this.child,
    this.onOpenChanged,
    this.onVisibilityChanged,
    this.onHoldChanged,
    this.ownsFocusNode = true,
    this.enableLongPress = true,
    this.opensAbove = false,
    this.focusNode,
  });

  /// Builds the menu's items given a callback that closes it. Called fresh
  /// every time the menu opens, so an item reflecting live state (a block
  /// flag, a permission) is never stale from an earlier open.
  ///
  /// The context handed over is this region's own, not the menu overlay's or
  /// the sheet's: those die with the menu the moment `close` runs, so an item
  /// that closed first and then opened a popover from that context opened it
  /// against a torn-down box - or nowhere. This one stays mounted and anchors
  /// to [child], which is where a member card or a submenu should land.
  final List<Widget> Function(BuildContext context, VoidCallback close)
  itemsBuilder;

  final Widget child;

  /// Told `true` right as the menu opens from a right-click and `false`
  /// right as it closes however that happens; never told `true` for a long
  /// press, which has no hover state on the touch device that sent it.
  /// `MessageContextMenuRegion` uses this to keep a row's hover-revealed
  /// controls mounted rather than reflowing under the open menu.
  final ValueChanged<bool>? onOpenChanged;

  /// [onOpenChanged]'s unconditional counterpart: told `true`/`false` on
  /// every real open or close, long press included, for a caller that wants
  /// to know the menu's own visibility rather than whether to keep a
  /// hover-revealed control mounted. A background highlight is exactly that
  /// caller - it has nothing to do with the picker button [onOpenChanged]
  /// exists for, and a long press deserves the same highlight a right-click
  /// gets even though it has no hover state to pin.
  final ValueChanged<bool>? onVisibilityChanged;

  /// Told `true` on press-down and `false` once the press is cancelled or
  /// commits, for a caller that shows hold progress across the long-press
  /// threshold. Null for a caller with no such visual.
  final ValueChanged<bool>? onHoldChanged;

  /// False when [child] is already its own tab stop (an [AppListRow], say),
  /// so the keyboard route rides that node instead of adding a second one.
  /// See [ContextMenuFocus.ownsFocusNode].
  final bool ownsFocusNode;

  /// False when [child] hosts a competing long-press gesture of its own (a
  /// held press that starts a drag, say) that must win the gesture arena
  /// instead. A right-click and the keyboard route are both unaffected -
  /// this only withholds the redundant long-press trigger, never the menu
  /// itself. See `channel_rail_reorder.dart`'s own doc comment for the
  /// concrete conflict this exists to resolve.
  final bool enableLongPress;

  /// Opens the anchored menu above [child]'s top-left instead of at the
  /// pointer, for a control docked near the bottom edge that it would cover.
  final bool opensAbove;

  /// The row's own tab stop, for a caller that drives focus itself; see
  /// [ContextMenuFocus.focusNode].
  final FocusNode? focusNode;

  @override
  State<ContextMenuRegion> createState() => ContextMenuRegionState();
}

/// Public so a caller that needs a second way into the same menu - a row's
/// own kebab, say - can reach it through a `GlobalKey<ContextMenuRegionState>`
/// and call [open] rather than keeping a second, divergent menu of its own.
/// See `channel_row_menu.dart`'s own doc comment for the concrete case this
/// exists for.
class ContextMenuRegionState extends State<ContextMenuRegion> {
  final _controller = AnimatedMenuController();
  Offset _anchor = Offset.zero;
  bool _sheetOpen = false;

  /// The list this row sits in, subscribed to only while the menu is open,
  /// so a wheel or trackpad scroll (which fires no pointer down and so never
  /// reaches `TapRegion.onTapOutside`) still closes a menu the scroll just
  /// carried away from the row it was anchored to.
  ScrollPosition? _watched;

  @override
  void dispose() {
    _watched?.removeListener(_closeOnScroll);
    super.dispose();
  }

  /// Opens the same menu a right-click or long-press would, for a caller
  /// with no pointer position of its own to anchor to - a kebab button, like
  /// the context-menu key [ContextMenuFocus] already handles the same way.
  ///
  /// [at], a global position, anchors the menu beside the control that asked
  /// instead of at the region's corner.
  void open({Offset? at}) => _setOpen(true, pointerGlobal: at);

  /// [pinRow] mirrors [onOpenChanged]'s own doc: true (the default) for a
  /// right-click and every close, false for a long press, which has nothing
  /// to pin.
  ///
  /// [pointerGlobal] anchors the menu to wherever the gesture that opened it
  /// landed. A real long press calls this twice (`onLongPressStart` then the
  /// bare `onLongPress` immediately after, both fired by the one recognizer),
  /// so the anchor is only taken on the first of the two: recomputing it on
  /// the second call, which carries no position, would throw the real one away.
  void _setOpen(bool open, {bool pinRow = true, Offset? pointerGlobal}) {
    // A close follows whichever surface is open, not the layout it has now.
    final sheet = open
        ? LayoutClass.of(context) == LayoutClass.compact
        : _sheetOpen;
    if (sheet) {
      _setSheetOpen(open, pinRow: pinRow);
      return;
    }
    if (!open && !_controller.isShowing) return;
    widget.onVisibilityChanged?.call(open);
    if (pinRow || !open) widget.onOpenChanged?.call(open);
    if (open && !_controller.isShowing) _anchor = _anchorOffset(pointerGlobal);
    _watchScroll(open);
    open ? _controller.show() : _controller.hide();
  }

  /// The sheet closes by scrim tap, drag, back gesture or an item, none of
  /// which pass through here, so "closed" is told when its future completes.
  void _setSheetOpen(bool open, {required bool pinRow}) {
    if (!open) {
      if (_sheetOpen) Navigator.of(context).maybePop();
      return;
    }
    if (_sheetOpen) return;
    _sheetOpen = true;
    widget.onVisibilityChanged?.call(true);
    if (pinRow) widget.onOpenChanged?.call(true);
    showAppSheet<void>(
      context,
      bare: true,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: AppSheetMenu(
          children: widget.itemsBuilder(
            context,
            () => Navigator.of(sheetContext).pop(),
          ),
        ),
      ),
    ).whenComplete(_onSheetClosed);
  }

  void _onSheetClosed() {
    _sheetOpen = false;
    if (!mounted) return;
    widget.onVisibilityChanged?.call(false);
    widget.onOpenChanged?.call(false);
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

  /// Anchors at [pointerGlobal], converted into the overlay's own coordinate
  /// space, when a mouse or touch opened the menu. Falls back to a fixed
  /// offset from the region's own corner only when nothing did - the
  /// context-menu key, which has no pointer position to give.
  Offset _anchorOffset(Offset? pointerGlobal) {
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return _rowInset;
    if (widget.opensAbove) {
      final box = context.findRenderObject() as RenderBox?;
      if (box != null) {
        final left = box.localToGlobal(Offset.zero, ancestor: overlay).dx;
        final dockTop = FloatingDockCard.topEdgeOf(context, overlay);
        if (dockTop != null) return Offset(left, dockTop - AppSpacing.s8);
        return box.localToGlobal(const Offset(0, -4), ancestor: overlay);
      }
    }
    if (pointerGlobal != null) {
      return overlay.globalToLocal(pointerGlobal) + _pointerInset;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return _rowInset;
    return box.localToGlobal(_rowInset, ancestor: overlay);
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller.portal,
      overlayChildBuilder: (overlayContext) => Positioned.fill(
        child: CustomSingleChildLayout(
          delegate: MessageMenuLayout(
            anchor: _anchor,
            above: widget.opensAbove,
            padding:
                MediaQuery.paddingOf(overlayContext) +
                const EdgeInsets.all(menuScreenMargin),
          ),
          child: AnimatedMenuSurface(
            controller: _controller,
            child: TapRegion(
              onTapOutside: (_) => _setOpen(false),
              child: ContextMenuKeyboardScope(
                onDismiss: () => _setOpen(false),
                child: SingleChildScrollView(
                  child: AppMenu(
                    width: 200,
                    children: widget.itemsBuilder(
                      context,
                      () => _setOpen(false),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      child: ContextMenuFocus(
        onOpen: () => _setOpen(true),
        ownsFocusNode: widget.ownsFocusNode,
        focusNode: widget.focusNode,
        child: GestureDetector(
          // Up, never down: only the up event belongs to the arena winner.
          onSecondaryTapUp: (details) =>
              _setOpen(true, pointerGlobal: details.globalPosition),
          // Kept out of the semantics tree once the child owns its own node; see this file's own doc comment for why.
          excludeFromSemantics: !widget.ownsFocusNode,
          // GestureDetector, never a raw recognizer: it is what publishes SemanticsAction.longPress, which context_menu_reachability_test guards.
          onLongPressDown:
              !widget.enableLongPress || widget.onHoldChanged == null
              ? null
              : (_) => widget.onHoldChanged!(true),
          onLongPressCancel:
              !widget.enableLongPress || widget.onHoldChanged == null
              ? null
              : () => widget.onHoldChanged!(false),
          // Carries the down position; bare onLongPress below fires right after it and carries none, kept only for its own SemanticsAction.longPress.
          onLongPressStart: !widget.enableLongPress
              ? null
              : (details) {
                  widget.onHoldChanged?.call(false);
                  _setOpen(
                    true,
                    pinRow: false,
                    pointerGlobal: details.globalPosition,
                  );
                },
          onLongPress: !widget.enableLongPress
              ? null
              : () => _setOpen(true, pinRow: false),
          child: widget.child,
        ),
      ),
    );
  }
}
