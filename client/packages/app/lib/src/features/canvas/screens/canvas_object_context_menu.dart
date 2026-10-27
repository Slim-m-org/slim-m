// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click on the canvas: front, back and delete over an object; paste
/// image, add note and recenter at the clicked point over empty space (an
/// owner request, 2026-08-29). Clear canvas stays out: it is destructive and
/// needs MANAGE_CANVAS, so it keeps the overflow menu's extra step.
///
/// It opens on secondary tap-up so a right-drag pan can never leave a menu
/// behind, and it wires no primary callback so drawing is untouched. Touch
/// gets it on a long press with the Select tool only, since every other tool
/// has already started drawing by then. The hit-catcher is excluded from
/// semantics because Flutter web would otherwise make it a full-canvas
/// button that swallows every gesture; the accessible route is
/// `CanvasSelectionSemantics` through [CanvasObjectMenuRequests].
library;

import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../../widgets/context_menu_focus.dart';
import 'canvas_object_locks.dart';
import '../../messages/widgets/message_context_menu_layout.dart';

/// Asks [CanvasObjectContextMenu] to open for an object with no pointer
/// behind it; notifies on every ask, so asking twice for one object works.
class CanvasObjectMenuRequests extends ChangeNotifier {
  String? objectId;

  void request(String objectId) {
    this.objectId = objectId;
    notifyListeners();
  }
}

class CanvasObjectContextMenu extends StatefulWidget {
  const CanvasObjectContextMenu({
    super.key,
    required this.document,
    required this.canManage,
    required this.selfId,
    required this.requests,
    required this.tool,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.onPasteImageAt,
    required this.onAddNoteAt,
    required this.onRecenter,
    required this.onToolChanged,
    this.onEditNote,
    this.canDraw = true,
  });

  final CanvasDocument document;

  /// False while the pane's error says placing would fail again; disables the
  /// empty-space items that place something, as the overflow menu does.
  final bool canDraw;

  /// Whether the caller holds MANAGE_CANVAS - widens which objects a
  /// right-click can resolve a target from, the same bit
  /// `CanvasOpsControllerSelect.beginSelect` reads for the identical reason.
  final bool canManage;
  final String? selfId;
  final CanvasObjectMenuRequests requests;

  /// The surface's currently active tool - read only to gate the touch
  /// long-press path below to the Select tool, where a pointer-down has
  /// already run [onSelectStart] rather than started an irreversible draw,
  /// erase or placement the way every other tool's pointer-down does.
  final CanvasTool tool;

  final ValueChanged<String> onBringToFront;
  final ValueChanged<String> onSendToBack;
  final ValueChanged<String> onDeleteSelected;

  /// The empty-space menu's "Paste image" item - `CanvasImagePaste.pasteAt`,
  /// the same clipboard-image pipeline the overflow menu's "Paste image"
  /// runs, aimed at the clicked point instead of the view's centre.
  final ValueChanged<Offset> onPasteImageAt;

  /// The empty-space menu's "Add note" item - the exact callback
  /// `CanvasSurface.onNotePlace` already is, so this is the same note-sheet
  /// flow a tap with the Note tool active produces, just reached without
  /// switching tools first.
  final ValueChanged<Offset> onAddNoteAt;

  /// The empty-space menu's "Recenter view" item - the pane's own
  /// always-available camera reset, identical to the overflow menu's copy.
  final VoidCallback onRecenter;

  /// A right-click on bare canvas under a drawing tool returns to Move through this.
  final ValueChanged<CanvasTool> onToolChanged;

  /// The object menu's "Edit note" item, shown over a note only: the touch
  /// and keyboard-free route to the editor a double click opens.
  final ValueChanged<String>? onEditNote;

  @override
  State<CanvasObjectContextMenu> createState() =>
      _CanvasObjectContextMenuState();
}

class _CanvasObjectContextMenuState extends State<CanvasObjectContextMenu> {
  final _controller = OverlayPortalController();
  Offset _anchor = Offset.zero;
  String? _target;

  /// Non-null exactly while the open overlay is the empty-space menu rather
  /// than the object one - the world point a paste or a note lands at once
  /// its item is picked. `_target` and this are never both non-null: every
  /// path that sets one clears the other first.
  Offset? _emptySpaceWorld;

  @override
  void initState() {
    super.initState();
    widget.requests.addListener(_onRequest);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    widget.requests.removeListener(_onRequest);
    super.dispose();
  }

  final Set<int> _heldPointers = {};
  Timer? _holdTimer;
  int? _holdPointer;
  Offset _holdLocal = Offset.zero;
  Offset _holdGlobal = Offset.zero;

  /// A touch or pen held still opens the menu. A timer here rather than a
  /// long-press recognizer: a recognizer joins the gesture arena, and one
  /// held finger would then reject the surface's pinch, or fire for a mouse.
  void _holdDown(PointerDownEvent event) {
    _heldPointers.add(event.pointer);
    _cancelHold();
    final touchLike =
        event.kind == PointerDeviceKind.touch ||
        event.kind == PointerDeviceKind.stylus;
    if (_heldPointers.length != 1 || !touchLike) return;
    _holdPointer = event.pointer;
    _holdLocal = event.localPosition;
    _holdGlobal = event.position;
    _holdTimer = Timer(kLongPressTimeout, () {
      _holdTimer = null;
      _onLongPress(_holdLocal, _holdGlobal);
    });
  }

  void _holdMove(PointerMoveEvent event) {
    if (event.pointer != _holdPointer) return;
    if ((event.localPosition - _holdLocal).distance > kTouchSlop) _cancelHold();
  }

  void _holdEnd(PointerEvent event) {
    _heldPointers.remove(event.pointer);
    if (event.pointer == _holdPointer) _cancelHold();
  }

  void _cancelHold() {
    _holdTimer?.cancel();
    _holdTimer = null;
    _holdPointer = null;
  }

  void _onRequest() {
    final id = widget.requests.objectId;
    if (id != null) _openFor(id, pointerGlobal: null);
  }

  bool _allowed(CanvasStroke stroke) =>
      widget.canManage ||
      (stroke.authorId != null && stroke.authorId == widget.selfId);

  /// The topmost object, the same one `beginSelect` would pick, so a
  /// right-click resolves to the target a left-click select would have.
  String? _hitTest(Offset world, {bool touch = false}) =>
      hitTestTopmost(widget.document, world, touch: touch, allowed: _allowed);

  Offset _toWorld(Offset local) {
    final camera = widget.document.camera;
    return Offset(
      camera.x + local.dx / camera.zoom,
      camera.y + local.dy / camera.zoom,
    );
  }

  /// Hit-test decides which menu this click opens, never both: an object
  /// under the cursor always wins, and only a genuine miss - the same
  /// "nothing here" result that used to end this gesture with no menu at
  /// all - opens the empty-space one instead.
  void _onSecondaryTapUp(TapUpDetails details) {
    final world = _toWorld(details.localPosition);
    final id = _hitTest(world);
    if (id != null) {
      _openFor(id, pointerGlobal: details.globalPosition);
    } else if (widget.tool != CanvasTool.pan) {
      widget.onToolChanged(CanvasTool.pan);
    } else {
      _openEmptySpace(world, details.globalPosition);
    }
  }

  /// The touch equivalent of [_onSecondaryTapUp] (desktop-vs-mobile rule 3),
  /// for the Select tool only.
  void _onLongPress(Offset local, Offset global) {
    if (widget.tool != CanvasTool.pan) return;
    final world = _toWorld(local);
    final id = _hitTest(world, touch: true);
    if (id != null) {
      _openFor(id, pointerGlobal: global);
    } else {
      _openEmptySpace(world, global);
    }
  }

  void _openFor(String id, {required Offset? pointerGlobal}) {
    if (widget.tool == CanvasTool.pan) {
      widget.document.selectedObjectId.value = id;
    }
    setState(() {
      _target = id;
      _emptySpaceWorld = null;
      _anchor = _anchorOffset(id, pointerGlobal);
    });
    _controller.show();
  }

  /// The empty-space menu always has a real pointer position behind it -
  /// unlike [_openFor], nothing reaches this without a right-click already
  /// in hand - so the anchor is a plain global-to-local conversion, the same
  /// one [_anchorOffset]'s own pointer branch performs for the object menu.
  void _openEmptySpace(Offset world, Offset pointerGlobal) {
    final overlayObject = Overlay.of(context).context.findRenderObject();
    final overlay = overlayObject is RenderBox ? overlayObject : null;
    setState(() {
      _target = null;
      _emptySpaceWorld = world;
      _anchor = overlay?.globalToLocal(pointerGlobal) ?? Offset.zero;
    });
    _controller.show();
  }

  /// Overlay-local, matching what [MessageMenuLayout] expects: a real
  /// pointer position converts global-to-local against the overlay itself,
  /// the same conversion `ContextMenuRegion` uses for a right-click; a
  /// keyboard-driven request with no pointer instead anchors at the
  /// selected object's own on-screen centre, converted through this
  /// widget's own box rather than a fixed corner, since unlike a message
  /// row this widget always knows exactly which object it is opening for.
  Offset _anchorOffset(String id, Offset? pointerGlobal) {
    final overlayObject = Overlay.of(context).context.findRenderObject();
    final overlay = overlayObject is RenderBox ? overlayObject : null;
    if (overlay == null) return Offset.zero;
    if (pointerGlobal != null) return overlay.globalToLocal(pointerGlobal);
    final boxObject = context.findRenderObject();
    final box = boxObject is RenderBox ? boxObject : null;
    final bounds = widget.document.objectBounds(id);
    if (box == null || bounds == null) return Offset.zero;
    final camera = widget.document.camera;
    final center = Offset(
      (bounds.x + bounds.w / 2 - camera.x) * camera.zoom,
      (bounds.y + bounds.h / 2 - camera.y) * camera.zoom,
    );
    return box.localToGlobal(center, ancestor: overlay);
  }

  void _close() => _controller.hide();

  void _bringToFront() {
    final id = _target;
    _close();
    if (id != null) widget.onBringToFront(id);
  }

  void _sendToBack() {
    final id = _target;
    _close();
    if (id != null) widget.onSendToBack(id);
  }

  void _editNote() {
    final id = _target;
    _close();
    if (id != null) widget.onEditNote?.call(id);
  }

  void _delete() {
    final id = _target;
    _close();
    if (id != null) widget.onDeleteSelected(id);
  }

  void _pasteImage() {
    final world = _emptySpaceWorld;
    _close();
    if (world != null) widget.onPasteImageAt(world);
  }

  void _addNote() {
    final world = _emptySpaceWorld;
    _close();
    if (world != null) widget.onAddNoteAt(world);
  }

  void _recenter() {
    _close();
    widget.onRecenter();
  }

  @override
  Widget build(BuildContext context) {
    return OverlayPortal(
      controller: _controller,
      overlayChildBuilder: (context) => Positioned.fill(
        child: Stack(
          children: [
            // Swallows the press that dismisses the menu, or the armed tool would act on it too.
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _close,
                onSecondaryTap: _close,
                excludeFromSemantics: true,
              ),
            ),
            Positioned.fill(
              child: CustomSingleChildLayout(
                delegate: MessageMenuLayout(
                  anchor: _anchor,
                  padding:
                      MediaQuery.paddingOf(context) +
                      const EdgeInsets.all(menuScreenMargin),
                ),
                child: ContextMenuKeyboardScope(
                  onDismiss: _close,
                  child: _target != null ? _objectMenu() : _emptySpaceMenu(),
                ),
              ),
            ),
          ],
        ),
      ),
      // translucent, not the default: a childless SizedBox registers no hit under deferToChild, and opaque would stop every primary-button event reaching CanvasSurface beneath.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: _onSecondaryTapUp,
        // Load-bearing, not tidiness - see this file's own library doc.
        excludeFromSemantics: true,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _holdDown,
          onPointerMove: _holdMove,
          onPointerUp: _holdEnd,
          onPointerCancel: _holdEnd,
          child: SizedBox.expand(
            // The badges ride on this full-surface layer; they take no pointer, so the hit catcher above is unchanged.
            child: switch (CanvasObjectLocksScope.maybeOf(context)) {
              final locks? => CanvasObjectLockBadges(
                document: widget.document,
                locks: locks,
              ),
              null => null,
            },
          ),
        ),
      ),
    );
  }

  bool _mayLock(String id) =>
      widget.canManage || widget.document.authorIdOf(id) == widget.selfId;

  bool _isNote(String? id) =>
      widget.onEditNote != null &&
      id != null &&
      (widget.document.kindOf(id) == CanvasObjectKind.note ||
          widget.document.kindOf(id) == CanvasObjectKind.text);

  Widget _objectMenu() {
    final locks = CanvasObjectLocksScope.maybeOf(context);
    final id = _target;
    final locked = id != null && (locks?.isLocked(id) ?? false);
    final mayLock = locks != null && id != null && _mayLock(id);
    final isNote = _isNote(id);
    return AppMenu(
      width: 200,
      children: [
        if (isNote)
          AppMenuItem(
            label: widget.document.kindOf(id!) == CanvasObjectKind.text
                ? 'Edit text'
                : 'Edit note',
            leading: AppIcons.edit,
            onTap: locked || !widget.canDraw ? null : _editNote,
          ),
        // A locked object refuses a restack or an erase, so those wait for Unlock.
        AppMenuItem(
          label: 'Bring to front',
          leading: AppIcons.bringToFront,
          onTap: locked ? null : _bringToFront,
        ),
        AppMenuItem(
          label: 'Send to back',
          leading: AppIcons.sendToBack,
          onTap: locked ? null : _sendToBack,
        ),
        if (mayLock)
          AppMenuItem(
            label: locked ? 'Unlock' : 'Lock in place',
            leading: locked ? AppIcons.tileUnlocked : AppIcons.tileLocked,
            onTap: () {
              _close();
              unawaited(locks.setLocked(id, !locked));
            },
          ),
        AppMenuItem(
          label: 'Delete',
          leading: AppIcons.delete,
          tone: AppMenuItemTone.danger,
          // A moderator's delete outranks a lock; an author unlocks their own first.
          onTap: locked && !widget.canManage ? null : _delete,
        ),
      ],
    );
  }

  /// Deliberately not the object menu's three items plus these three - see
  /// this file's own library doc for why "Clear canvas" specifically stays
  /// out even though the overflow menu offers it too.
  Widget _emptySpaceMenu() {
    return AppMenu(
      width: 200,
      children: [
        AppMenuItem(
          label: 'Paste image',
          leading: AppIcons.clipboardPaste,
          onTap: widget.canDraw ? _pasteImage : null,
        ),
        AppMenuItem(
          label: 'Add note',
          leading: AppIcons.note,
          onTap: widget.canDraw ? _addNote : null,
        ),
        AppMenuItem(
          label: 'Recenter view',
          leading: AppIcons.recenter,
          onTap: _recenter,
        ),
      ],
    );
  }
}
