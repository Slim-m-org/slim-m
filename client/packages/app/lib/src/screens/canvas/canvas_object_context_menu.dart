// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A right-click on the canvas: over an object, bring to front/send to
/// back/delete - the same three verbs the overflow menu already offers a
/// selection, reached directly at the object under the cursor instead of a
/// select-then-open-the-overflow-menu round trip. Over empty space, a
/// smaller menu of paste-image, add-note and recenter, each anchored (or
/// placed) at the exact point clicked - see this file's own doc, below,
/// for why that second menu exists now when it once deliberately did not.
///
/// **Why not `ContextMenuRegion`.** That widget wraps one static child as
/// the gesture target and opens on tap-DOWN, both wrong here: a canvas
/// object is painted, not a widget, so the target has to be resolved by
/// hit-testing at the pointer's own position rather than fixed at
/// construction; and opening on tap-down would show a menu before a
/// competing right-drag pan (built separately, on this same surface) ever
/// gets to declare itself a drag. This widget reuses everything about
/// `ContextMenuRegion` that does transfer - [MessageMenuLayout]'s anchored
/// positioning, [ContextMenuKeyboardScope]'s Escape/Tab route, [AppMenu]'s
/// body - and only rebuilds the gesture detection and target resolution
/// that a painted surface actually needs.
///
/// **Tap-up, not tap-down, is what makes this immune to a right-drag pan
/// on the same surface, regardless of how that pan turns out to be built.**
/// [GestureDetector.onSecondaryTapUp] only fires once a secondary-button
/// press releases without exceeding the platform's own tap slop; a real
/// drag either cancels this tap outright (if the pan is a competing
/// `GestureRecognizer` restricted to the same button, Flutter's own arena
/// resolves the two exactly the way a tap and a pan already disambiguate
/// anywhere else in this codebase) or never registers with it at all (if
/// the pan instead reads `event.buttons` off the surface's own raw
/// `Listener`, which this widget's tap recognizer neither blocks nor is
/// blocked by - a `Listener` and a `GestureDetector` at the same point both
/// see every raw event independently). Either way there is no window in
/// which a drag can leave a menu open behind it.
///
/// **The gesture layer is deliberately button-scoped rather than
/// button-blind.** Only `onSecondaryTapUp` is wired, and
/// `TapGestureRecognizer.isPointerAllowed` (read from source, not assumed)
/// refuses a primary-button pointer outright the moment no primary
/// callback is set - so this layer cannot compete for, delay, or otherwise
/// affect an ordinary left-button draw, erase or select gesture on the
/// surface beneath it.
///
/// **Empty canvas used to do nothing, deliberately - overridden 2026-08-29
/// on direct owner request** ("no basic right click on canvas for quick
/// actions"). The reasoning below was real at the time and is kept rather
/// than deleted, since the owner's ask supersedes it rather than proving it
/// wrong: there genuinely was no established "act on this exact point" set
/// of canvas-wide actions, and the toolbar's overflow menu genuinely already
/// reached everything canvas-wide from one place regardless of the cursor.
/// What changed is not that reasoning, only the answer to whether reaching
/// those same actions *at the cursor* is worth a menu - the owner decided it
/// is. The three items chosen (paste image, add note, recenter) are exactly
/// the overflow menu's own always-available, non-destructive verbs, placed
/// or anchored at the clicked point instead of the view's centre or nowhere
/// in particular; "Clear canvas" is deliberately excluded even though the
/// overflow menu carries it too, both because it needs MANAGE_CANVAS (the
/// two other menus this file already builds gate nothing so this new one
/// would be the first to need a permission check) and because a destructive,
/// confirm-gated action sitting one row from "Paste image" in a menu that
/// opens on every stray right-click is a bad adjacency to introduce - a
/// manager clearing the canvas is already one deliberate trip to the
/// overflow menu away, which is exactly the friction `CanvasOverflowMenu`'s
/// own doc says that action is supposed to keep. The same tap-up gesture
/// arena and hit-test-first ordering below is what a pan-in-progress and an
/// object-vs-empty-space right-click were already immune to; opening a
/// second menu shape from the same resolved-to-nothing hit test adds no new
/// gesture surface, so every claim in this file about drags and semantics
/// still holds for it unchanged.
///
/// **Deliberately duplicated with the overflow menu's own selection-gated
/// items, not moved.** The overflow menu - reachable from the bar on every
/// platform - stays a second route to bring-to-front/send-to-back/delete;
/// removing them there to avoid the overlap would be a real regression for
/// a user who has not found the long-press path below yet.
///
/// **Touch's long-press equivalent (`onLongPressStart`) is gated to the
/// Select tool.** Every other tool's raw pointer-down starts a stroke
/// draft, an erase or a placement the instant a finger lands, well before
/// any long-press timer could fire, so teaching this to open under a
/// drawing tool would draw or place *and* pop a menu 500ms later. The
/// Select tool's own pointer-down only calls `onSelectStart`, which a menu
/// opening on top of moments later changes nothing about - see
/// `_onLongPressStart`'s own doc.
///
/// **Keyboard and screen-reader route: `CanvasSelectionSemantics`, not a
/// tab stop of this widget's own.** A canvas object has no focus node to
/// hang `ContextMenuFocus`'s row-tab-stop model on; the one accessibility
/// node an object already gets once selected is exactly where a custom
/// "open its actions" route belongs instead. [CanvasObjectMenuRequests] is
/// the small bus that carries that request here with no pointer position
/// behind it - the same gap `ContextMenuRegion`'s own context-menu-key
/// fallback covers for a message row, anchored here at the selected
/// object's own screen-space centre rather than a fixed corner, since
/// unlike a row this widget always knows exactly what it is opening for.
///
/// **`excludeFromSemantics: true` on the hit-catcher, and it is load-bearing
/// rather than tidiness.** Wiring `onSecondaryTapUp` alone still makes
/// `RawGestureDetector` build a `TapGestureRecognizer` (needed to detect any
/// tap variant, secondary included), and Flutter's own default semantics
/// delegate (`_DefaultSemanticsGestureDelegate._getTapHandler`, read from
/// the framework source rather than assumed) exposes `SemanticsAction.tap`
/// the moment *any* `TapGestureRecognizer` exists, regardless of which tap
/// callback it actually carries. Without the exclusion this childless
/// `SizedBox.expand()` became a full-canvas `role="button"` node the moment
/// semantics were ever engaged (a screen reader, or anything else that
/// turns Flutter's accessibility tree on) - Flutter's web renderer sets
/// `pointer-events: all` on any such actionable node, which sits in front
/// of `CanvasSurface` and silently swallows every draw, erase, select and
/// placement gesture with no visible error, since the recognizer this
/// invented "tap" would actually invoke has no `onTap` of its own to call.
/// The accessible route to these three actions was never this node's job in
/// the first place - see the paragraph above - so nothing is lost by
/// telling Flutter this hit-catcher has no accessibility meaning of its
/// own.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../widgets/context_menu_focus.dart';
import 'canvas_object_locks.dart';
import '../../widgets/message_context_menu_layout.dart';

/// A request to open [CanvasObjectContextMenu] for a specific object with no
/// pointer position behind it - see this file's own doc for the keyboard and
/// screen-reader route this exists for.
///
/// Notifies unconditionally on every [request] call, never gated on whether
/// [objectId] actually changed: a `ValueNotifier`'s equality gate would
/// silently swallow a second ask for the same object (open, dismiss, ask
/// again), the same trap `canvas_activity_log.dart`'s own `announcementTick`
/// doc comment already names for an identical shape.
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
    required this.onToolChanged,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.onPasteImageAt,
    required this.onAddNoteAt,
    required this.onRecenter,
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

  /// Switches the surface to the Move tool once a target resolves, so the
  /// object a right-click just found is immediately draggable and
  /// resizable with no separate tool switch - the same closing move
  /// `canvas_pane_gestures.dart`'s `_selectPlaced` makes after placing one.
  final ValueChanged<CanvasTool> onToolChanged;
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
    widget.requests.removeListener(_onRequest);
    super.dispose();
  }

  void _onRequest() {
    final id = widget.requests.objectId;
    if (id != null) _openFor(id, pointerGlobal: null);
  }

  bool _allowed(CanvasStroke stroke) =>
      widget.canManage ||
      (stroke.authorId != null && stroke.authorId == widget.selfId);

  /// Box kinds first, a stroke only if no box was hit - the exact precedence
  /// `beginSelect` already establishes for the select tool's own pointer
  /// down, so a right-click resolves to the same target a left-click select
  /// would have.
  String? _hitTest(Offset world) =>
      hitTestBoxAt(widget.document, world, allowed: _allowed) ??
      hitTestStroke(widget.document, world, allowed: _allowed);

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
    } else {
      _openEmptySpace(world, details.globalPosition);
    }
  }

  /// The touch equivalent of [_onSecondaryTapUp] - desktop-vs-mobile rule 3.
  /// Gated to the Select tool, not to a particular pointer kind: every
  /// other tool's own raw pointer-down already committed a draw, erase or
  /// placement before this timer could ever fire, exactly the collision
  /// this file's own library doc names as the reason a long press was
  /// rejected before. The Select tool's pointer-down only selects, which a
  /// menu opening on top of moments later changes nothing about, and a real
  /// mouse drag-select cancels this recognizer at the first move past slop
  /// the same way any long press does.
  void _onLongPressStart(LongPressStartDetails details) {
    if (widget.tool != CanvasTool.pan) return;
    final world = _toWorld(details.localPosition);
    final id = _hitTest(world);
    if (id != null) {
      _openFor(id, pointerGlobal: details.globalPosition);
    } else {
      _openEmptySpace(world, details.globalPosition);
    }
  }

  void _openFor(String id, {required Offset? pointerGlobal}) {
    widget.document.selectedObjectId.value = id;
    widget.onToolChanged(CanvasTool.pan);
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
        child: CustomSingleChildLayout(
          delegate: MessageMenuLayout(
            anchor: _anchor,
            padding:
                MediaQuery.paddingOf(context) +
                const EdgeInsets.all(menuScreenMargin),
          ),
          child: TapRegion(
            onTapOutside: (_) => _close(),
            child: ContextMenuKeyboardScope(
              onDismiss: _close,
              child: _target != null ? _objectMenu() : _emptySpaceMenu(),
            ),
          ),
        ),
      ),
      // translucent, not the default: a childless SizedBox registers no hit under deferToChild, and opaque would stop every primary-button event reaching CanvasSurface beneath.
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onSecondaryTapUp: _onSecondaryTapUp,
        onLongPressStart: _onLongPressStart,
        // Load-bearing, not tidiness - see this file's own library doc.
        excludeFromSemantics: true,
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
    );
  }

  Widget _objectMenu() {
    final locks = CanvasObjectLocksScope.maybeOf(context);
    final id = _target;
    final locked = id != null && (locks?.isLocked(id) ?? false);
    final mayLock =
        locks != null &&
        id != null &&
        (widget.canManage || widget.document.authorIdOf(id) == widget.selfId);
    return AppMenu(
      width: 200,
      children: [
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
          onTap: locked ? null : _delete,
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
