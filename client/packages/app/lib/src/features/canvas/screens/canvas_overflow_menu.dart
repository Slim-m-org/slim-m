// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas bar's overflow: "Add image from file" is always present, since
/// placing an image needs only the USE_CANVAS bit drawing already does;
/// "Show activity log" is there while a screen reader is on, since the log is
/// that reader's fallback for the drawing; "Bring to front"/"Send to back"/
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
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/confirm_dialog.dart';
import '../providers/canvas_grid_snap.dart';
import 'canvas_chat_toggle.dart';
import 'canvas_module_tile_scope.dart';
import '../../voice/providers/voice_chat_unread.dart';
import '../../voice/widgets/voice_chat_unread_dot.dart';
import '../widgets/canvas_clear_scope.dart';
import '../widgets/canvas_clear_sheet.dart';
import 'canvas_overflow_sections.dart';
import 'canvas_people_sheet.dart';
import '../../../widgets/context_menu_focus.dart';
import '../../../widgets/dock_collapse.dart' show DockPopupPin;
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
    this.onAddImageFile,
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
    this.fullscreen = false,
    required this.tool,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.hasSelfBubble,
    required this.selfBubbleHidden,
    required this.onToggleSelfBubbleHidden,
    required this.hiddenTiles,
    required this.onShowTile,
    this.opensBelow = false,
    this.scopedClear,
    this.chatChannelId,
    this.toolsHidden = false,
    this.onToggleToolsHidden,
    this.readOnly = false,
  });

  /// The voice channel whose text chat a row here opens, for a header with no room for its own toggle; null for none.
  final String? chatChannelId;

  /// Null hides "Clear part of the canvas".
  final CanvasScopedClear? scopedClear;

  /// Opens under the button rather than over it, for a trigger in the header.
  final bool opensBelow;

  /// Picks an image file to place; null where the canvas cannot place one.
  final VoidCallback? onAddImageFile;

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

  /// Drops the pane's chrome, or restores it while [fullscreen] is on.
  final VoidCallback onToggleFullscreen;
  final bool fullscreen;

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

  /// Whether the drawing tools are folded away, and the item that flips it; null offers none.
  final bool toolsHidden;
  final VoidCallback? onToggleToolsHidden;

  /// A spectator: only the items that change this viewer's own view.
  final bool readOnly;

  @override
  State<CanvasOverflowMenu> createState() => _CanvasOverflowMenuState();
}

class _CanvasOverflowMenuState extends State<CanvasOverflowMenu> {
  final _controller = OverlayPortalController();

  /// Puts the trigger inside the open menu's tap region, so pressing it again closes the menu.
  final _tapGroup = Object();

  /// Mirrors the portal's visibility for the trigger's expanded state.
  final _open = ValueNotifier<bool>(false);

  /// The context of the phone sheet while one is up, which `_hide` pops.
  BuildContext? _sheet;

  void _hide() {
    final sheet = _sheet;
    if (sheet != null) {
      _sheet = null;
      Navigator.of(sheet).pop();
    }
    _controller.hide();
    _open.value = false;
  }

  void _toggle() {
    if (MediaQuery.sizeOf(context).width < kCompactWidth) {
      unawaited(_openSheet());
      return;
    }
    _controller.toggle();
    _open.value = _controller.isShowing;
  }

  /// A phone gets the sheet every other phone menu is, per `desktop-vs-mobile.md`.
  Future<void> _openSheet() async {
    _open.value = true;
    await showAppSheet<void>(
      context,
      bare: true,
      builder: (sheet) {
        _sheet = sheet;
        return ValueListenableBuilder<String?>(
          valueListenable: widget.selection,
          builder: (context, selected, _) =>
              AppSheetMenu(children: _menuItems(context, selected)),
        );
      },
    );
    _sheet = null;
    if (mounted) _open.value = false;
  }

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  final _link = LayerLink();

  void _toggleActivityLog() {
    _hide();
    widget.onToggleActivityLog();
  }

  void _enterFullscreen() {
    _hide();
    widget.onToggleFullscreen();
  }

  void _toggleSelfBubble() {
    _hide();
    widget.onToggleSelfBubbleHidden();
  }

  /// Opens a modal once the menu is gone: its closing focus scope would otherwise take focus back from the new route.
  void _openAfterClose(Future<void> Function() open) {
    _hide();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(open());
    });
  }

  void _openParticipants() =>
      _openAfterClose(() => showCanvasPeopleSheet(context));

  void _requestScopedClear(CanvasScopedClear control) =>
      _openAfterClose(() => requestScopedCanvasClear(context, control));

  void _showTile(String key) {
    _hide();
    widget.onShowTile(key);
  }

  /// The confirmation names the real Undo path rather than claiming
  /// permanence: `CanvasOpsController.clear()` arms a genuine, server-backed
  /// Undo for exactly this action (a `restore` op against the clear's own
  /// `deleted_at` fence), and the audience who sees this dialog is the same
  /// audience whose own dock carries the Undo control that would
  /// immediately falsify a "cannot be undone" claim.
  void _requestClear() => _openAfterClose(_confirmClear);

  Future<void> _confirmClear() async {
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
        // Says whether its menu is open, as a disclosure button should.
        child: ValueListenableBuilder<bool>(
          valueListenable: _open,
          builder: (context, open, _) => TapRegion(
            groupId: _tapGroup,
            child: Semantics(
              expanded: open,
              child: Consumer(
                builder: (context, ref, button) {
                  final id = widget.chatChannelId;
                  return VoiceChatToggleDot(
                    unread:
                        id != null &&
                        ref.watch(canvasHasChatProvider(id)) &&
                        ref.watch(voiceChatUnreadProvider(id)),
                    toggle: button!,
                  );
                },
                child: AppIconButton(
                  icon: AppIcons.moreVertical,
                  semanticLabel: 'More canvas actions',
                  tooltip: 'More canvas actions',
                  onPressed: _toggle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _bringToFront(String objectId) {
    _hide();
    widget.onBringToFront(objectId);
  }

  void _sendToBack(String objectId) {
    _hide();
    widget.onSendToBack(objectId);
  }

  void _delete(String objectId) {
    _hide();
    widget.onDeleteSelected(objectId);
  }

  void _pickShapeKind(CanvasShapeKind kind) {
    _hide();
    widget.onShapeKindChanged(kind);
  }

  /// The height between the trigger and the screen edge the menu opens toward, so a short screen scrolls it instead of cutting rows off.
  double _roomForMenu() {
    final box = context.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return double.infinity;
    final screen = MediaQuery.sizeOf(context);
    final insets = MediaQuery.paddingOf(context);
    final top = box.localToGlobal(Offset.zero).dy;
    final room = widget.opensBelow
        ? screen.height - insets.bottom - top - box.size.height
        : top - insets.top;
    return math.max(room - AppSpacing.s8, AppSizes.icon28 * 3);
  }

  /// `width: 280` below: 200 truncated this menu's own longest labels
  /// ("Hide my camera bubble") to
  /// "Hide my camera bu…" - narrower than `AppMenu`'s own 250
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
        child: DockPopupPin(
          child: TapRegion(
            groupId: _tapGroup,
            onTapOutside: (_) => _hide(),
            // The same keyboard route the message context menu already earned: Tab reaches every item once open, and Escape closes it.
            child: ContextMenuKeyboardScope(
              onDismiss: _hide,
              child: ValueListenableBuilder<String?>(
                valueListenable: widget.selection,
                builder: (context, selected, _) => AppMenu(
                  width: 280,
                  maxHeight: _roomForMenu(),
                  children: _menuItems(context, selected),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  CanvasOverflowSections get _sections => CanvasOverflowSections(
    hiddenTiles: widget.hiddenTiles,
    tool: widget.tool,
    shapeKind: widget.shapeKind,
    canManage: widget.canManage,
    scopedClear: widget.scopedClear,
    onShowTile: _showTile,
    onPickShapeKind: _pickShapeKind,
    onBringToFront: _bringToFront,
    onSendToBack: _sendToBack,
    onDelete: _delete,
    onClear: _requestClear,
    onScopedClear: _requestScopedClear,
  );

  List<Widget> _menuItems(BuildContext context, String? selected) {
    return [
      if (widget.onAddImageFile case final addImage? when !widget.readOnly)
        AppMenuItem(
          label: 'Add image from file',
          leading: AppIcons.image,
          onTap: widget.canDraw
              ? () => _openAfterClose(() async => addImage())
              : null,
        ),
      if (!widget.readOnly)
        CanvasModuleTileScope.menuItems(
          open: (place) => _openAfterClose(() async => place()),
        ),
      AppMenuItem(
        label: widget.fullscreen ? 'Exit fullscreen' : 'Enter fullscreen',
        leading: AppIcons.expand,
        onTap: _enterFullscreen,
      ),
      if (widget.onToggleToolsHidden case final toggle?)
        AppMenuItem(
          label: widget.toolsHidden
              ? 'Show drawing tools'
              : 'Hide drawing tools',
          leading: AppIcons.pen,
          onTap: () {
            _hide();
            toggle();
          },
        ),
      if (widget.chatChannelId case final id?)
        Consumer(
          builder: (context, ref, _) => !ref.watch(canvasHasChatProvider(id))
              ? const SizedBox.shrink()
              : AppMenuItem(
                  label: ref.watch(voiceChatUnreadProvider(id))
                      ? 'Text chat, new messages'
                      : 'Text chat',
                  leading: AppIcons.chat,
                  onTap: () => _openAfterClose(
                    () => showCanvasChatSheet(this.context, id),
                  ),
                ),
        ),
      ..._withDivider([
        // A screen reader's fallback for the drawing; a sighted viewer already sees what it lists.
        if (widget.activityLogOpen ||
            MediaQuery.accessibleNavigationOf(context))
          AppMenuItem(
            label: widget.activityLogOpen
                ? 'Hide activity log'
                : 'Show activity log',
            leading: AppIcons.activityLog,
            onTap: _toggleActivityLog,
          ),
        if (!widget.readOnly)
          Consumer(
            builder: (context, ref, _) => AppMenuItem(
              label: ref.watch(canvasGridSnapProvider)
                  ? 'Stop snapping to grid'
                  : 'Snap to grid',
              leading: AppIcons.snapToGrid,
              onTap: () {
                _hide();
                unawaited(ref.read(canvasGridSnapProvider.notifier).toggle());
              },
            ),
          ),
        if (widget.hasSelfBubble) ...[
          AppMenuItem(
            label: 'People here',
            leading: AppIcons.members,
            onTap: _openParticipants,
          ),
          _selfBubbleItem(),
        ],
      ]),
      ..._sections.hiddenTileItems(),
      if (!widget.readOnly) ...[
        ..._sections.shapeKindItems(),
        if (selected != null) ..._sections.selectionItems(selected),
        ..._sections.manageItems(),
      ],
    ];
  }

  /// A section with its divider, or nothing at all when the section is empty.
  static List<Widget> _withDivider(List<Widget> items) =>
      items.isEmpty ? const [] : [const AppMenuDivider(), ...items];

  Widget _selfBubbleItem() => AppMenuItem(
    label: widget.selfBubbleHidden
        ? 'Show my camera bubble'
        : 'Hide my camera bubble',
    leading: AppIcons.camera,
    onTap: _toggleSelfBubble,
  );
}
