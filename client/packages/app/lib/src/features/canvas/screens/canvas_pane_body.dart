// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's widget tree: the identity strip, the error and
/// truncation banners, the drawing surface, the floating call-and-canvas
/// dock, and the text activity log a screen reader can browse in place of
/// the surface.
///
/// Split out of `canvas_pane.dart`, which was already past the review
/// budget. `_CanvasPaneState` owns every callback and every piece of state
/// that has to survive the pane's own lifetime; whether the activity panel
/// is open right now is pure presentation, so it is this widget's own local
/// state instead of one more field threaded through an already-large parent.
library;

import '../widgets/canvas_clear_scope.dart' show CanvasScopedClear;
import 'dart:async';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_activity_log.dart';
import 'canvas_activity_panel.dart';
import 'canvas_bar.dart';
import 'canvas_call_dock.dart';
import 'canvas_compact_dock.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_hidden_tiles.dart';
import 'canvas_people_session.dart';
import 'canvas_view_relay.dart';
import 'canvas_object_context_menu.dart';
import 'canvas_tool_wheel_layer.dart';
import '../providers/canvas_pen_style.dart';
import 'canvas_pane_hints.dart';
import 'canvas_pane_overlays.dart';
import 'canvas_pane_surface.dart';
import 'canvas_pane_surface_actions.dart';
import 'canvas_short_toggle.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_layer.dart';
import 'canvas_speaking_sync.dart';
import 'canvas_summary.dart';
import 'canvas_summon_request.dart' show leaveFullscreenThenSettle;
import 'canvas_board_pager.dart' show CanvasPaging;
import 'canvas_paging_indicator.dart';
import 'canvas_banners.dart';

part 'canvas_pane_body_builders.dart';

class CanvasPaneBody extends StatefulWidget {
  const CanvasPaneBody({
    super.key,
    required this.channelId,
    required this.onClose,
    this.onActivityLogOpenChanged,
    required this.tool,
    required this.onToolChanged,
    required this.canUndo,
    required this.onUndo,
    required this.canRedo,
    required this.onRedo,
    required this.canManage,
    required this.document,
    required this.onClear,
    this.scopedClear,
    required this.onPasteImage,
    this.onAddImageFile,
    required this.onPasteImageAt,
    required this.onRecenter,
    required this.onBringIntoBoard,
    required this.error,
    required this.onDismissError,
    this.onRetryError,
    required this.truncated,
    this.paging,
    required this.loading,
    required this.onStroke,
    required this.onErase,
    required this.onEraseEnd,
    this.onEraseCancel,
    this.onSelectCancel,
    required this.onSelectStart,
    required this.onSelectDrag,
    required this.onSelectEnd,
    required this.onNotePlace,
    this.onTextPlace,
    this.onSelectLongPress,
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
    this.onPointerLeft,
    this.remoteDrafts,
    this.onDraftPoint,
    this.onDraftEnded,
    this.onDraftCancel,
    this.callParticipants = const [],
    this.blockedTileKeys = const {},
    required this.cameraViewFor,
    required this.screenShareViewFor,
    required this.tileOverrides,
    this.viewMode,
    required this.onCommitTile,
    required this.onVideoInterest,
    required this.selfBubbleHidden,
    required this.onToggleSelfBubbleHidden,
    required this.fullscreen,
    required this.onToggleFullscreen,
    this.focusedTileKey,
    this.onFocusTile,
    this.callDock,
    this.callError,
    this.onRetryCall,
    this.participantMenuItemsBuilder,
    this.onSelectTap,
    this.onEditNote,
    this.noteSpans,
    this.noteSpansRevision = 0,
    this.noteEditor,
    this.viewRelay,
    this.boardFocusNode,
  });

  final String channelId;
  final VoidCallback onClose;

  /// Focus node handed down to [CanvasBoardKeys].
  final FocusNode? boardFocusNode;

  /// Told when the activity log replaces the board, so the pane's edit keys stand down.
  final ValueChanged<bool>? onActivityLogOpenChanged;

  /// Follow and bring-everyone; null hides both.
  final CanvasViewRelay? viewRelay;
  final CanvasTool tool;
  final ValueChanged<CanvasTool> onToolChanged;
  final bool canUndo;
  final VoidCallback onUndo;
  final bool canRedo;
  final VoidCallback onRedo;
  final bool canManage;
  final CanvasDocument document;
  final Future<void> Function() onClear;
  final CanvasScopedClear? scopedClear;

  /// The toolbar's "Paste image" action, always available - the manual
  /// fallback that works on every platform, the same shape the composer's
  /// own "+" sheet row already is.
  final VoidCallback onPasteImage;

  /// Picks an image file to place; null where the canvas cannot place one.
  final VoidCallback? onAddImageFile;

  /// The empty-canvas right-click menu's own "Paste image" item - the same
  /// pipeline as [onPasteImage], aimed at the clicked world point instead of
  /// the view's centre. See `CanvasObjectContextMenu`'s own doc for why that
  /// menu exists now.
  final ValueChanged<Offset> onPasteImageAt;

  /// Fits the view to the drawn content: the zoom chip's tap and a menu item.
  final VoidCallback onRecenter;

  /// Moves objects the board cannot hold whole back onto it.
  final VoidCallback onBringIntoBoard;
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

  /// Set while the rest of a big board is still arriving.
  final CanvasPaging? paging;
  final bool loading;
  final StrokeCommitted onStroke;
  final ValueChanged<Offset> onErase;
  final VoidCallback onEraseEnd;
  final VoidCallback? onEraseCancel;
  final VoidCallback? onSelectCancel;
  final ValueChanged<Offset> onSelectStart;
  final ValueChanged<Offset> onSelectDrag;
  final VoidCallback onSelectEnd;

  /// A select gesture that was a tap rather than a drag; see
  /// [CanvasSurface.onSelectTap].
  final void Function(Offset world, PointerDeviceKind kind)? onSelectTap;
  final ValueChanged<String>? onEditNote;

  /// Styles a note's text, and the revision that says when it changed.
  final NoteSpanBuilder? noteSpans;
  final int noteSpansRevision;

  /// The in-place note editor while one is open, drawn over the surface.
  final Widget? noteEditor;
  final ValueChanged<Offset> onNotePlace;
  final ValueChanged<Offset>? onTextPlace;
  final ValueChanged<Offset>? onSelectLongPress;
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
  final VoidCallback? onPointerLeft;

  /// Other participants' in-flight strokes. Null renders no layer, the same
  /// "cheap to omit" shape [cursors] already offers.
  final RemoteStrokeDrafts? remoteDrafts;
  final DraftPointAdded? onDraftPoint;
  final VoidCallback? onDraftEnded;
  final VoidCallback? onDraftCancel;

  /// Who is on this channel's call right now, already filtered for
  /// blocking - empty whenever there is no call here, or this viewer has not
  /// joined it, in which case [CanvasPresenceLayer] renders nothing. Self and
  /// remote are one list now - see that layer's own doc for why the caller's
  /// own tile used to live in a separate, screen-anchored overlay and no
  /// longer does.
  final List<VoiceParticipant> callParticipants;

  /// Blocked callers' tile keys: hidden, but still counted when default tile spots are laid out.
  final Set<String> blockedTileKeys;
  final CameraViewBuilder cameraViewFor;
  final ScreenShareViewBuilder screenShareViewFor;

  /// Every tile's own drag, resize, lock and hide - see
  /// `canvas_presence_layer.dart`'s own doc for why this lives here rather
  /// than as a `CanvasDocument` field.
  final CanvasPresenceTileOverrides tileOverrides;
  final CanvasViewMode? viewMode;

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

  /// The call tile shown full pane under the ink, and the way to change it.
  final String? focusedTileKey;
  final ValueChanged<String?>? onFocusTile;

  /// Non-null exactly when this device is connected to a call in this
  /// channel right now - `canvas_pane.dart`'s own `callDockDataFor` decides.
  /// The dock renders a call section only then; it always renders a canvas
  /// section, since this widget only exists while the canvas itself is open.
  final CallDockData? callDock;

  /// Why this device's call in this channel failed or dropped, with the way to join again; null while it is not failed.
  final String? callError;
  final VoidCallback? onRetryCall;

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
  final _toolWheel = CanvasToolWheelController();

  /// One resolution of the call tiles for both the backdrop and the layer.
  final _presenceFrames = CanvasPresenceFrameResolver();

  /// Whether this caller has a camera bubble on the canvas at all right now
  /// - the dock's overflow item's own gate for whether "hide my camera
  /// bubble" means anything to offer.
  void _acceptSummon() {
    final leave = widget.fullscreen ? widget.onToggleFullscreen : null;
    unawaited(
      widget.viewRelay?.acceptSummon(
            beforeMoving: leave == null
                ? null
                : () => leaveFullscreenThenSettle(leave),
          ) ??
          Future<void>.value(),
    );
  }

  bool get _hasSelfBubble => widget.callParticipants.any((p) => p.isLocal);

  /// Which tiles are hidden, for the phone header's Show rows; it notifies only when that set changes.
  HiddenTileKeys? _hiddenKeys;

  // Built on first read: dispose must not build one from overrides already disposed.
  HiddenTileKeys get _hiddenTiles =>
      _hiddenKeys ??= HiddenTileKeys(widget.tileOverrides);

  @override
  void didUpdateWidget(covariant CanvasPaneBody oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tileOverrides != widget.tileOverrides) {
      _hiddenKeys?.dispose();
      _hiddenKeys = null;
    }
  }

  @override
  void dispose() {
    _hiddenKeys?.dispose();
    _menuRequests.dispose();
    _toolWheel.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _presenceFrames.layoutOnlyKeys = widget.blockedTileKeys;
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final size = MediaQuery.sizeOf(context);
    final compact = size.width < kCompactWidth;
    // A short window gives the header's height to the board; the dock repeats its controls and the member toggle floats.
    final shortWindow = size.height < kShortHeight && !compact;
    // Left stays unconsumed in windowed mode because a rail occupies the true left edge; fullscreen claims the edge and respects its cutout.
    return Container(
      color: tokens.surfaceBase,
      child: SafeArea(
        left: widget.fullscreen,
        child: Column(
          children: [
            // Fullscreen can drop the header whole without taking an action with it: its controls are the dock's, repeated.
            if (!widget.fullscreen && !shortWindow)
              CanvasBar(
                channelId: widget.channelId,
                // Rebuilt when the hidden set changes, so a tile hidden later gets its Show row here too.
                trailing: compact
                    ? ListenableBuilder(
                        listenable: _hiddenTiles,
                        builder: (context, _) =>
                            CanvasCompactEditGroup(canvas: _dockData()),
                      )
                    : null,
              ),
            Expanded(
              child: CanvasPeopleHost(
                relay: widget.viewRelay,
                cursors: widget.cursors,
                selfId: widget.selfId,
                viewMode: widget.viewMode,
                onBringEveryone: () => widget.viewRelay?.summonEveryone(
                  widget.document.visibleBoard ?? canvasSharedArea,
                ),
                // Canvas content panned past the top edge must never paint over the header above it.
                child: ClipRect(
                  // Tab goes banner action, board, dock, call tiles, view controls: reading order put the board's corners first.
                  child: FocusTraversalGroup(
                    policy: OrderedTraversalPolicy(),
                    child: Stack(
                      children: [
                        FocusTraversalOrder(
                          key: const ValueKey('canvas-surface'),
                          order: const NumericFocusOrder(1),
                          child: _activityLogOpen ? _panel() : _surface(tokens),
                        ),
                        CanvasSpeakingSync(cursors: widget.cursors),
                        if (!_activityLogOpen)
                          FocusTraversalOrder(
                            key: const ValueKey('canvas-peer-controls'),
                            order: const NumericFocusOrder(4),
                            child: CanvasPeerControls(
                              participants: widget.callParticipants,
                              cursors: widget.cursors,
                              relay: widget.viewRelay,
                              selfId: widget.selfId,
                              onAcceptSummon: _acceptSummon,
                            ),
                          ),
                        if (widget.paging case final paging?)
                          CanvasPagingIndicator(paging: paging),
                        FocusTraversalOrder(
                          key: const ValueKey('canvas-banners'),
                          order: const NumericFocusOrder(0),
                          child: CanvasBanners(
                            callError: widget.callError,
                            onRetryCall: widget.onRetryCall,
                            error: widget.error,
                            onDismissError: widget.onDismissError,
                            onRetryError: widget.onRetryError,
                            truncated: widget.truncated,
                            unsavedInk: widget.document.unsavedInk.count,
                          ),
                        ),
                        FocusTraversalOrder(
                          key: const ValueKey('canvas-dock'),
                          order: const NumericFocusOrder(2),
                          child: CanvasDockOverlay(
                            call: widget.callDock,
                            canvas: _dockData,
                            tileOverrides: widget.tileOverrides,
                            compact: compact,
                          ),
                        ),
                        if (shortWindow && !widget.fullscreen)
                          FocusTraversalOrder(
                            key: const ValueKey('canvas-short-toggle'),
                            order: const NumericFocusOrder(3),
                            child: CanvasShortToggle(
                              channelId: widget.channelId,
                            ),
                          ),
                        const FocusTraversalOrder(
                          key: ValueKey('canvas-music-badge'),
                          order: NumericFocusOrder(5),
                          child: CanvasMusicBadge(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Mounted regardless of the panel's own open state: browsing history is optional, hearing about it is not.
            CanvasActivityAnnouncer(activityLog: widget.activityLog),
          ],
        ),
      ),
    );
  }

  void _toggleActivityLog() {
    setState(() => _activityLogOpen = !_activityLogOpen);
    widget.onActivityLogOpenChanged?.call(_activityLogOpen);
  }
}
