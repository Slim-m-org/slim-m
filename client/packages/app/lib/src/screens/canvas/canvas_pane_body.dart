// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's widget tree: the identity strip, the error and
/// truncation banners, the drawing surface, the floating call-and-canvas
/// dock, and the text activity log a screen reader can browse in place of
/// the surface.
///
/// Split out of `canvas_pane.dart`, which was already past the review
/// budget before this slice added the eraser, undo and clear controls to
/// it. `_CanvasPaneState` owns every callback and every piece of state that
/// has to survive the pane's own lifetime; whether the activity panel is
/// open right now is pure presentation, so it is this widget's own local
/// state instead of one more field threaded through an already-large parent.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import '../../widgets/dock_height_reporter.dart';
import 'canvas_activity_log.dart';
import 'canvas_activity_panel.dart';
import 'canvas_bar.dart';
import 'canvas_call_dock.dart';
import 'canvas_compact_dock.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_hidden_tiles.dart';
import 'canvas_object_context_menu.dart';
import 'canvas_pen_style.dart';
import 'canvas_pane_hints.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_layer.dart';
import 'canvas_presence_roster.dart';
import 'canvas_summary.dart';
import 'canvas_selection_semantics.dart';
import 'canvas_world_edge_glow.dart';
import 'canvas_zoom_indicator.dart';

class CanvasPaneBody extends StatefulWidget {
  const CanvasPaneBody({
    super.key,
    required this.channelId,
    required this.onClose,
    required this.tool,
    required this.onToolChanged,
    required this.canUndo,
    required this.onUndo,
    required this.canManage,
    required this.document,
    required this.onClear,
    required this.onPasteImage,
    required this.onPasteImageAt,
    required this.onRecenter,
    required this.error,
    required this.onDismissError,
    this.onRetryError,
    required this.truncated,
    required this.loading,
    required this.onStroke,
    required this.onErase,
    required this.onEraseEnd,
    required this.onSelectStart,
    required this.onSelectDrag,
    required this.onSelectEnd,
    required this.onNotePlace,
    required this.onShapePlace,
    required this.shapeKind,
    required this.onShapeKindChanged,
    required this.pen,
    required this.onPenChanged,
    required this.onBringToFront,
    required this.onSendToBack,
    required this.onDeleteSelected,
    required this.selfId,
    required this.activityLog,
    this.cursors,
    this.cursorColors = const [],
    this.onPointerMoved,
    this.remoteDrafts,
    this.onDraftPoint,
    this.onDraftEnded,
    this.callParticipants = const [],
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.tileOverrides,
    required this.onCommitTile,
    required this.onVideoInterest,
    required this.selfBubbleHidden,
    required this.onToggleSelfBubbleHidden,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.callDock,
    this.participantMenuItemsBuilder,
  });

  final String channelId;
  final VoidCallback onClose;
  final CanvasTool tool;
  final ValueChanged<CanvasTool> onToolChanged;
  final bool canUndo;
  final VoidCallback onUndo;
  final bool canManage;
  final CanvasDocument document;
  final Future<void> Function() onClear;

  /// The toolbar's "Paste image" action, always available - the manual
  /// fallback that works on every platform, the same shape the composer's
  /// own "+" sheet row already is.
  final VoidCallback onPasteImage;

  /// The empty-canvas right-click menu's own "Paste image" item - the same
  /// pipeline as [onPasteImage], aimed at the clicked world point instead of
  /// the view's centre. See `CanvasObjectContextMenu`'s own doc for why that
  /// menu exists now.
  final ValueChanged<Offset> onPasteImageAt;

  /// The toolbar's "Recenter view" action, always available - see
  /// `CanvasOverflowMenu`'s own doc for the gap this closes.
  final VoidCallback onRecenter;
  final String? error;
  final VoidCallback onDismissError;

  /// Re-runs the viewport fetch that produced [error] - non-null only for
  /// the almost-certainly-transient "could not be loaded" case, where the
  /// one recovery on screen used to be closing and reopening the pane, with
  /// nothing on screen telling a person to do that. Null for every other
  /// error this pane shows (forbidden, refused, timeout freeze), each of
  /// which would just fail the identical way again.
  final VoidCallback? onRetryError;
  final bool truncated;
  final bool loading;
  final StrokeCommitted onStroke;
  final ValueChanged<Offset> onErase;
  final VoidCallback onEraseEnd;
  final ValueChanged<Offset> onSelectStart;
  final ValueChanged<Offset> onSelectDrag;
  final VoidCallback onSelectEnd;
  final ValueChanged<Offset> onNotePlace;
  final ShapePlaced onShapePlace;

  /// The primitive the next tap with the shape tool places, and the bar's
  /// own picker for changing it.
  final CanvasShapeKind shapeKind;
  final ValueChanged<CanvasShapeKind> onShapeKindChanged;
  final CanvasPenStyle pen;
  final ValueChanged<CanvasPenStyle> onPenChanged;
  final ValueChanged<String> onBringToFront;
  final ValueChanged<String> onSendToBack;

  /// Removes the current selection - an image, note or shape - the select
  /// tool's own counterpart to the eraser removing a stroke. Never offered
  /// with nothing selected, the same gating [onBringToFront] already uses.
  final ValueChanged<String> onDeleteSelected;

  /// This caller's own id, for [CanvasObjectContextMenu]'s ownership check -
  /// the same "own it, or hold MANAGE_CANVAS" gate `beginSelect` already
  /// applies to a left-click select.
  final String? selfId;

  /// The accessibility fallback: who placed, moved, removed, cleared or
  /// restored what, filtered for blocking exactly as a remote cursor
  /// already is. Owned by `_CanvasPaneState` and outlives a panel toggle,
  /// so the history survives closing and reopening the panel within one
  /// session.
  final CanvasActivityLog activityLog;

  /// Other participants' live pointers, and the palette their colours are
  /// drawn from. Null renders no cursor layer, the same "cheap to omit"
  /// shape [CanvasSurface] itself already offers.
  final CanvasCursors? cursors;
  final List<Color> cursorColors;
  final PointerMoved? onPointerMoved;

  /// Other participants' in-flight strokes. Null renders no layer, the same
  /// "cheap to omit" shape [cursors] already offers.
  final RemoteStrokeDrafts? remoteDrafts;
  final DraftPointAdded? onDraftPoint;
  final VoidCallback? onDraftEnded;

  /// Who is on this channel's call right now, already filtered for
  /// blocking - empty whenever there is no call here, or this viewer has not
  /// joined it, in which case [CanvasPresenceLayer] renders nothing. Self and
  /// remote are one list now - see that layer's own doc for why the caller's
  /// own tile used to live in a separate, screen-anchored overlay and no
  /// longer does.
  final List<VoiceParticipant> callParticipants;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;

  /// Every tile's own drag, resize, lock and hide - see
  /// `canvas_presence_layer.dart`'s own doc for why this lives here rather
  /// than as a `CanvasDocument` field.
  final CanvasPresenceTileOverrides tileOverrides;

  /// Sends one tile key's current arrangement to the server - see
  /// `CanvasPresenceLayer.onCommit`'s own doc for exactly when this fires.
  final void Function(String key, Rect rect) onCommitTile;

  /// Which tiles currently want video, forwarded from [CanvasPresenceLayer]
  /// to the live session; see that widget's own [onVideoInterest] doc.
  final void Function(Set<String>? tileKeys) onVideoInterest;

  /// The caller's own standing "never show my own camera" preference -
  /// distinct from [tileOverrides], which is per-call; see
  /// `canvas_self_presence.dart`'s own doc for why the two are split.
  final bool selfBubbleHidden;

  /// Threaded to the floating dock's overflow menu, the one place this pane
  /// offers to flip [selfBubbleHidden] - see that menu's own doc for why it
  /// lives there rather than as a dedicated bar icon.
  final VoidCallback onToggleSelfBubbleHidden;

  /// Whether this canvas has dropped its chrome to show nothing but the
  /// surface, and the one control that flips it - see
  /// `canvas_fullscreen.dart`'s own doc for exactly what goes and what
  /// deliberately stays.
  final bool fullscreen;
  final VoidCallback onToggleFullscreen;

  /// Non-null exactly when this device is connected to a call in this
  /// channel right now - `canvas_pane.dart`'s own `callDockDataFor` decides.
  /// The dock renders a call section only then; it always renders a canvas
  /// section, since this widget only exists while the canvas itself is open.
  final CallDockData? callDock;

  /// Forwarded straight to [CanvasPresenceLayer.participantMenuItemsBuilder]
  /// - see that field's own doc.
  final List<Widget> Function(
    BuildContext context,
    VoiceParticipant participant,
    VoidCallback close,
  )?
  participantMenuItemsBuilder;

  @override
  State<CanvasPaneBody> createState() => _CanvasPaneBodyState();
}

class _CanvasPaneBodyState extends State<CanvasPaneBody> {
  bool _activityLogOpen = false;

  /// Pure presentation, the same reason `_activityLogOpen` above is local
  /// state rather than one more field threaded through `_CanvasPaneState`:
  /// which object a right-click or a screen-reader action is asking about
  /// right now outlives nothing beyond this body's own lifetime.
  final _menuRequests = CanvasObjectMenuRequests();

  /// One resolution of the call tiles for both the backdrop and the layer.
  final _presenceFrames = CanvasPresenceFrameResolver();

  /// Whether this caller has a camera bubble on the canvas at all right now
  /// - the dock's overflow item's own gate for whether "hide my camera
  /// bubble" means anything to offer.
  bool get _hasSelfBubble => widget.callParticipants.any((p) => p.isLocal);

  @override
  void dispose() {
    _menuRequests.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final compact = MediaQuery.sizeOf(context).width < kCompactWidth;
    // No AppBar sits above CanvasBar, so this pane insets itself for top/bottom; left stays unconsumed because a rail, not this pane, ever occupies the true left edge.
    return Container(
      color: tokens.surfaceBase,
      child: SafeArea(
        left: false,
        child: Column(
          children: [
            // Fullscreen can drop the header whole without taking an action with it: its controls are the dock's, repeated.
            if (!widget.fullscreen)
              CanvasBar(
                channelId: widget.channelId,
                trailing: compact
                    ? CanvasCompactEditGroup(canvas: _dockData())
                    : null,
              ),
            if (widget.error != null)
              Padding(
                padding: const EdgeInsets.all(AppSpacing.s12),
                child: AppErrorState(
                  message: widget.error!,
                  onDismiss: widget.onDismissError,
                  onRetry: widget.onRetryError,
                ),
              ),
            if (widget.truncated)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.s12,
                  0,
                  AppSpacing.s12,
                  AppSpacing.s12,
                ),
                child: const AppCallout(
                  child: Text(
                    'Some ink in this region is not shown. Zoom in to see it.',
                  ),
                ),
              ),
            Expanded(
              child: Stack(
                children: [
                  _activityLogOpen ? _panel() : _surface(tokens),
                  if (!_activityLogOpen)
                    CanvasPresenceRoster(
                      callParticipants: widget.callParticipants,
                      cursors: widget.cursors,
                    ),
                  Align(
                    alignment: Alignment.bottomCenter,
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.s12),
                      // The dock's own hidden-tiles list has to notice a hide or show landing in tileOverrides, which nothing else here rebuilds this widget for.
                      child: DockHeightReporter(
                        child: ListenableBuilder(
                          listenable: widget.tileOverrides,
                          builder: (context, _) => CanvasCallDock(
                            call: widget.callDock,
                            canvas: _dockData(),
                            compact: compact,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Mounted regardless of the panel's own open state: browsing history is optional, hearing about it is not.
            CanvasActivityAnnouncer(activityLog: widget.activityLog),
          ],
        ),
      ),
    );
  }

  CanvasDockData _dockData() => CanvasDockData(
    tool: widget.tool,
    onToolChanged: widget.onToolChanged,
    // A banner already says a place would fail; pen/note/shape must not stay selectable underneath it.
    canDraw: !canvasErrorBlocksDrawing(widget.error),
    canUndo: widget.canUndo,
    onUndo: widget.onUndo,
    canManage: widget.canManage,
    onClear: widget.onClear,
    onPasteImage: widget.onPasteImage,
    onRecenter: widget.onRecenter,
    selection: widget.document.selectedObjectId,
    onBringToFront: widget.onBringToFront,
    onSendToBack: widget.onSendToBack,
    onDeleteSelected: widget.onDeleteSelected,
    activityLogOpen: _activityLogOpen,
    onToggleActivityLog: () =>
        setState(() => _activityLogOpen = !_activityLogOpen),
    shapeKind: widget.shapeKind,
    onShapeKindChanged: widget.onShapeKindChanged,
    pen: widget.pen,
    onPenChanged: widget.onPenChanged,
    onClose: widget.onClose,
    hasSelfBubble: _hasSelfBubble,
    selfBubbleHidden: widget.selfBubbleHidden,
    onToggleSelfBubbleHidden: widget.onToggleSelfBubbleHidden,
    hiddenTiles: hiddenCanvasTiles(
      participants: widget.callParticipants,
      overrides: widget.tileOverrides,
    ),
    onShowTile: (key) => widget.tileOverrides.setHidden(key, false),
    fullscreen: widget.fullscreen,
    onToggleFullscreen: widget.onToggleFullscreen,
  );

  /// `document.objectCount` is the same trigger `_surface` already listens
  /// to, since a placed or removed object is exactly what changes
  /// `liveCountsByKind` too - without this, the summary would freeze at
  /// whatever it read when the panel was last opened, since nothing else
  /// rebuilds this widget on a live document change by design.
  Widget _panel() => ValueListenableBuilder<int>(
    valueListenable: widget.document.objectCount,
    builder: (context, count, child) => CanvasActivityPanel(
      activityLog: widget.activityLog,
      summary: canvasSummary(widget.document),
      objectCount: count,
    ),
  );

  Widget _surface(AppTokens tokens) => ValueListenableBuilder<int>(
    valueListenable: widget.document.objectCount,
    builder: (context, count, child) => Semantics(
      container: true,
      label: widget.loading
          ? 'Canvas, loading'
          : 'Canvas, ${canvasSummary(widget.document)}',
      child: Stack(
        children: [
          child!,
          // A blank canvas otherwise looks identical to a broken one; the screen-reader label above already says so for a screen reader, and this is the sighted-user half of that same guarantee.
          if (widget.loading)
            CanvasLoadingHint(tokens: tokens)
          // Not over an error banner (see the hint's own doc), nor over a call's participant tiles, where "nothing here yet" contradicts the video feeds already on screen.
          else if (count == 0 &&
              widget.error == null &&
              widget.callParticipants.isEmpty)
            CanvasEmptyHint(tokens: tokens),
        ],
      ),
    ),
    child: Stack(
      children: [
        // Below everything, including CanvasPresenceBackdrop - a grid line must never paint over a sent-to-back tile's own video, the bug this ordering fixes.
        CanvasGridLayer(document: widget.document, line: tokens.borderSubtle),
        // Before CanvasSurface, so a sent-to-back tile's own pixels sit under real ink - see canvas_presence_layer.dart's own doc for why its controls stay in the layer below regardless.
        CanvasPresenceBackdrop(
          document: widget.document,
          participants: widget.callParticipants,
          cameraViewFor: widget.cameraViewFor,
          screenShareViewFor: widget.screenShareViewFor,
          overrides: widget.tileOverrides,
          hideSelfCamera: widget.selfBubbleHidden,
          resolver: _presenceFrames,
        ),
        CanvasSurface(
          document: widget.document,
          ink: AppCanvasColors.annotation,
          inkColors: canvasPenInkByKey,
          penInk: widget.pen.color,
          strokeWidth: widget.pen.width,
          // AppTokens.stripe: its own doc reserves it for exactly this state.
          placeholderFill: tokens.stripe,
          placeholderIcon: tokens.textDisabled,
          // AppShadows.float: its own doc names a dragged canvas object as exactly what this token is for.
          elevationShadow: AppShadows.float,
          selectionOutline: tokens.accentFill,
          selectionHandleFill: tokens.surfaceRaised,
          selectionHandleBorder: tokens.accentFill,
          noteColor: AppCanvasColors.note,
          shapeColor: AppCanvasColors.shape,
          noteTextInk: tokens.textPrimary,
          onStroke: widget.onStroke,
          tool: widget.tool,
          onErase: widget.onErase,
          onEraseEnd: widget.onEraseEnd,
          onSelectStart: widget.onSelectStart,
          onSelectDrag: widget.onSelectDrag,
          onSelectEnd: widget.onSelectEnd,
          onNotePlace: widget.onNotePlace,
          onShapePlace: widget.onShapePlace,
          shapeKind: widget.shapeKind,
          cursors: widget.cursors,
          cursorColors: widget.cursorColors,
          cursorLabelFontFamily: AppFonts.sans,
          // Zero under reduce motion, which keeps the stepped positions.
          cursorGlide: AppMotion.reduced(context, cursorGlideDuration),
          onPointerMoved: widget.onPointerMoved,
          remoteDrafts: widget.remoteDrafts,
          onDraftPoint: widget.onDraftPoint,
          onDraftEnded: widget.onDraftEnded,
        ),
        CanvasObjectContextMenu(
          document: widget.document,
          canManage: widget.canManage,
          selfId: widget.selfId,
          requests: _menuRequests,
          tool: widget.tool,
          onToolChanged: widget.onToolChanged,
          onBringToFront: widget.onBringToFront,
          onSendToBack: widget.onSendToBack,
          onDeleteSelected: widget.onDeleteSelected,
          onPasteImageAt: widget.onPasteImageAt,
          onAddNoteAt: widget.onNotePlace,
          canDraw: !canvasErrorBlocksDrawing(widget.error),
          onRecenter: widget.onRecenter,
        ),
        CanvasSelectionSemantics(
          document: widget.document,
          onOpenActions: _menuRequests.request,
        ),
        // Last, on top of CanvasObjectContextMenu's hit catcher - see canvas_presence_tile.dart's own doc for why a right-click on a tile is absorbed rather than reaching an object underneath it.
        CanvasPresenceLayer(
          document: widget.document,
          participants: widget.callParticipants,
          cameraViewFor: widget.cameraViewFor,
          screenShareViewFor: widget.screenShareViewFor,
          overrides: widget.tileOverrides,
          onCommit: widget.onCommitTile,
          onVideoInterest: widget.onVideoInterest,
          hideSelfCamera: widget.selfBubbleHidden,
          tool: widget.tool,
          participantMenuItemsBuilder: widget.participantMenuItemsBuilder,
          resolver: _presenceFrames,
        ),
        // Topmost and non-interactive - see its own doc for why a pan or a tile drag stopping at worldLimit otherwise looks like nothing happened.
        CanvasWorldEdgeGlow(
          document: widget.document,
          tileOverrides: widget.tileOverrides,
          tokens: tokens,
        ),
        CanvasZoomIndicator(document: widget.document, tokens: tokens),
      ],
    ),
  );
}
