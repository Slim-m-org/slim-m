// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas bar's overflow: "Paste image" and "Show/Hide activity log" are
/// always present, since placing an image needs only the USE_CANVAS bit
/// drawing already does and the activity log is an accessibility fallback
/// nobody should need a permission for; "Bring to front"/"Send to back"/
/// "Delete" appear only while something is selected and "Clear canvas"
/// appears only for MANAGE_CANVAS. The four shape-kind rows appear only
/// while the Shape tool is active - not on the fixed-height bar itself,
/// which has no room for a fourth control per tool, and this menu already
/// has room to grow. "Hide/Show my camera bubble" appears only while the
/// caller is actually on this channel's call - there is nothing to toggle
/// otherwise - and lives here rather than as a dedicated bar icon for the
/// same crowding reason the activity log toggle already does.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../widgets/confirm_dialog.dart';
import '../../widgets/context_menu_focus.dart';
import 'canvas_shape_icons.dart';
import 'canvas_tools_row.dart' show CanvasHiddenTile;

/// The bar's own overflow trigger and the confirm dialog behind Clear.
///
/// Clear stays behind a menu item rather than a bare button even when it is
/// the only reason a manager opens this: the extra tap is deliberate
/// friction on the one control here that removes more than the caller's own
/// selection, matching `manage_channel_sheet.dart`'s own danger-zone
/// separation. Delete needs no such friction: it takes exactly the one
/// object already selected, the same immediacy the eraser tool already
/// gives a stroke.
class CanvasOverflowMenu extends StatefulWidget {
  const CanvasOverflowMenu({
    super.key,
    required this.onPasteImage,
    required this.canDraw,
    required this.canManage,
    required this.onClear,
    required this.selection,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.activityLogOpen,
    required this.onToggleActivityLog,
    required this.onToggleFullscreen,
    required this.tool,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.hasSelfBubble,
    required this.selfBubbleHidden,
    required this.onToggleSelfBubbleHidden,
    required this.hiddenTiles,
    required this.onShowTile,
    this.opensBelow = false,
  });

  /// Opens under the button rather than over it, for a trigger in the header.
  final bool opensBelow;

  final VoidCallback onPasteImage;

  /// False while the pane's own error banner is up - see
  /// `canvas_tools_row.dart`'s `canDraw` for the full reasoning; this is the
  /// same signal reaching the CTA's other named affordance, "paste an
  /// image".
  final bool canDraw;

  final bool canManage;
  final Future<void> Function() onClear;

  /// The bar's own current tool, read only to decide whether the shape-kind
  /// rows below apply - this menu never changes it.
  final CanvasTool tool;
  final CanvasShapeKind shapeKind;
  final ValueChanged<CanvasShapeKind> onShapeKindChanged;

  /// The one object currently selected for a resize or reorder, or null.
  /// "Bring to front"/"Send to back" appear only while this holds an id,
  /// the same "no button that would just do nothing" choice
  /// `AppSegmentedOption.disabled` already makes elsewhere on this canvas.
  final ValueListenable<String?> selection;
  final ValueChanged<String> onBringToFront;
  final ValueChanged<String> onSendToBack;

  /// Removes the current selection outright - an image, note, shape, or a
  /// reorder-selected stroke - with no confirm dialog, the same immediacy
  /// the eraser tool already gives a stroke it hit-tests directly. Undo
  /// reverses it exactly the way it reverses an erase.
  final ValueChanged<String> onDeleteSelected;

  /// The accessibility fallback's own open state, so the item's label says
  /// which way a tap goes rather than a bare "Activity log" that reads the
  /// same whether it opens or closes the panel.
  final bool activityLogOpen;
  final VoidCallback onToggleActivityLog;

  /// Drops the pane's chrome. Only ever reached from here to *enter*: this
  /// menu's own button is inside the strip fullscreen folds away, so the way
  /// back is the dock's own always-visible button, plus Escape.
  final VoidCallback onToggleFullscreen;

  /// Whether the caller has a camera bubble on this canvas at all right now
  /// - see `canvas_bar.dart`'s own doc on why the toggle below is absent
  /// rather than merely disabled when this is false.
  final bool hasSelfBubble;
  final bool selfBubbleHidden;
  final VoidCallback onToggleSelfBubbleHidden;

  /// Every remote tile hidden on this viewer's own canvas this call, and
  /// the recovery action for each - see [CanvasHiddenTile]'s own doc for
  /// why a hide must stay reversible.
  final List<CanvasHiddenTile> hiddenTiles;
  final ValueChanged<String> onShowTile;

  @override
  State<CanvasOverflowMenu> createState() => _CanvasOverflowMenuState();
}

class _CanvasOverflowMenuState extends State<CanvasOverflowMenu> {
  final _controller = OverlayPortalController();
  final _link = LayerLink();

  void _paste() {
    _controller.hide();
    widget.onPasteImage();
  }

  void _toggleActivityLog() {
    _controller.hide();
    widget.onToggleActivityLog();
  }

  void _enterFullscreen() {
    _controller.hide();
    widget.onToggleFullscreen();
  }

  void _toggleSelfBubble() {
    _controller.hide();
    widget.onToggleSelfBubbleHidden();
  }

  void _showTile(String key) {
    _controller.hide();
    widget.onShowTile(key);
  }

  /// The confirmation names the real Undo path rather than claiming
  /// permanence: `CanvasOpsController.clear()` arms a genuine, server-backed
  /// Undo for exactly this action (a `restore` op against the clear's own
  /// `deleted_at` fence), and the audience who sees this dialog is the same
  /// audience whose own dock carries the Undo control that would
  /// immediately falsify a "cannot be undone" claim.
  Future<void> _requestClear() async {
    _controller.hide();
    const message =
        'This removes everything on this canvas, including objects outside '
        'your current view, for everyone in this channel.';
    final confirmed = await confirmDangerousAction(
      context,
      title: 'Clear this canvas?',
      message:
          '$message You can undo this with Undo until you close the '
          'canvas or take many more actions.',
      confirmLabel: 'Clear canvas',
      cancelLabel: 'Keep canvas',
    );
    if (confirmed) await widget.onClear();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _link,
      child: OverlayPortal(
        controller: _controller,
        overlayChildBuilder: (_) => _buildMenu(),
        child: AppIconButton(
          icon: AppIcons.moreVertical,
          semanticLabel: 'More canvas actions',
          tooltip: 'More canvas actions',
          onPressed: _controller.toggle,
        ),
      ),
    );
  }

  void _bringToFront(String objectId) {
    _controller.hide();
    widget.onBringToFront(objectId);
  }

  void _sendToBack(String objectId) {
    _controller.hide();
    widget.onSendToBack(objectId);
  }

  void _delete(String objectId) {
    _controller.hide();
    widget.onDeleteSelected(objectId);
  }

  void _pickShapeKind(CanvasShapeKind kind) {
    _controller.hide();
    widget.onShapeKindChanged(kind);
  }

  Widget _shortcutHint(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const AppKbd('Ctrl'),
        Padding(
          // Off-grid on purpose: matches AppKbd's own sub-4dp padding so "Ctrl+V" reads as one shortcut, not two chips with a gap between.
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Text(
            '+',
            style: AppText.micro.copyWith(color: tokens.textSecondary),
          ),
        ),
        const AppKbd('V'),
      ],
    );
  }

  /// `width: 280` below: 200 truncated this menu's own longest labels
  /// ("Paste image" with its Ctrl+V hint, "Hide my camera bubble") to
  /// "Paste i…"/"Hide my camera bu…" - narrower than `AppMenu`'s own 250
  /// default for no reason tied to this menu's own content.
  Widget _buildMenu() {
    return Positioned(
      left: 0,
      top: 0,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        // Upward by default: the trigger lives in the floating dock near the bottom of the pane.
        targetAnchor: widget.opensBelow
            ? Alignment.bottomRight
            : Alignment.topRight,
        followerAnchor: widget.opensBelow
            ? Alignment.topRight
            : Alignment.bottomRight,
        offset: Offset(0, widget.opensBelow ? 4 : -4),
        child: TapRegion(
          onTapOutside: (_) => _controller.hide(),
          // The same keyboard route the message context menu already earned: Tab reaches every item once open, and Escape closes it.
          child: ContextMenuKeyboardScope(
            onDismiss: _controller.hide,
            child: ValueListenableBuilder<String?>(
              valueListenable: widget.selection,
              builder: (context, selected, _) => AppMenu(
                width: 280,
                children: [
                  AppMenuItem(
                    label: 'Paste image',
                    leading: AppIcons.clipboardPaste,
                    // Ctrl+V already works from anywhere in the pane (see canvas_pane.dart's CallbackShortcuts); nothing said so until this hint, and a touch layout drops it, the same "no finger can press it" rule the channel search field's own Ctrl+K hint already follows. Dropped entirely while canDraw is false: a shortcut hint for an action that would fail is not worth keeping.
                    trailing: !widget.canDraw || AppTouchTargets.of(context)
                        ? null
                        : _shortcutHint(context),
                    onTap: widget.canDraw ? _paste : null,
                  ),
                  // The way in only: the way out is the dock's own button, since this menu is part of the tool strip fullscreen folds away.
                  AppMenuItem(
                    label: 'Enter fullscreen',
                    leading: AppIcons.expand,
                    onTap: _enterFullscreen,
                  ),
                  const AppMenuDivider(),
                  AppMenuItem(
                    label: widget.activityLogOpen
                        ? 'Hide activity log'
                        : 'Show activity log',
                    leading: AppIcons.activityLog,
                    onTap: _toggleActivityLog,
                  ),
                  if (widget.hasSelfBubble)
                    AppMenuItem(
                      label: widget.selfBubbleHidden
                          ? 'Show my camera bubble'
                          : 'Hide my camera bubble',
                      leading: AppIcons.camera,
                      onTap: _toggleSelfBubble,
                    ),
                  if (widget.hiddenTiles.isNotEmpty) ...[
                    const AppMenuDivider(),
                    for (final tile in widget.hiddenTiles)
                      AppMenuItem(
                        label: 'Show ${tile.label}',
                        leading: AppIcons.tileHide,
                        onTap: () => _showTile(tile.key),
                      ),
                  ],
                  if (widget.tool == CanvasTool.shape) ...[
                    const AppMenuDivider(),
                    for (final kind in CanvasShapeKind.values)
                      AppMenuItem(
                        label: canvasShapeKindLabel(kind),
                        leading: canvasShapeKindIcon(kind),
                        selected: widget.shapeKind == kind,
                        onTap: () => _pickShapeKind(kind),
                      ),
                  ],
                  if (selected != null) ...[
                    const AppMenuDivider(),
                    AppMenuItem(
                      label: 'Bring to front',
                      leading: AppIcons.bringToFront,
                      onTap: () => _bringToFront(selected),
                    ),
                    AppMenuItem(
                      label: 'Send to back',
                      leading: AppIcons.sendToBack,
                      onTap: () => _sendToBack(selected),
                    ),
                    AppMenuItem(
                      label: 'Delete',
                      leading: AppIcons.delete,
                      tone: AppMenuItemTone.danger,
                      onTap: () => _delete(selected),
                    ),
                  ],
                  if (widget.canManage) ...[
                    const AppMenuDivider(),
                    AppMenuItem(
                      label: 'Clear canvas',
                      leading: AppIcons.delete,
                      tone: AppMenuItemTone.danger,
                      onTap: () => unawaited(_requestClear()),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
