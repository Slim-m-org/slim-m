// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's drawing layers, bottom to top: grid, focused feed, call-tile video,
/// ink surface, object menu, call-tile controls, note editor and edge indicators.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_focused_feed.dart';
import 'canvas_forbidden_message.dart';
import 'canvas_board_keys.dart';
import 'canvas_board_object_semantics.dart';
import 'canvas_object_context_menu.dart';
import 'canvas_pane_surface_actions.dart';
import 'canvas_pen_style.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_layer.dart';
import 'canvas_selection_semantics.dart';
import 'canvas_world_edge_glow.dart';
import 'canvas_zoom_indicator.dart';

/// Lays out the layers; the pane body owns the state and passes it in.
class CanvasPaneSurface extends StatelessWidget {
  const CanvasPaneSurface({
    super.key,
    required this.actions,
    required this.callParticipants,
    required this.canManage,
    required this.cursorColors,
    required this.cursors,
    required this.document,
    required this.error,
    required this.noteEditor,
    required this.noteSpans,
    required this.noteSpansRevision,
    required this.pen,
    required this.remoteDrafts,
    required this.selfBubbleHidden,
    required this.selfId,
    required this.shapeKind,
    required this.tileOverrides,
    this.viewMode,
    required this.tool,
    required this.tokens,
    required this.menuRequests,
    required this.presenceFrames,
    this.focusedTileKey,
  });

  final CanvasPaneSurfaceActions actions;
  final List<VoiceParticipant> callParticipants;
  final bool canManage;
  final List<Color> cursorColors;
  final CanvasCursors? cursors;
  final CanvasDocument document;
  final String? error;
  final Widget? noteEditor;
  final NoteSpanBuilder? noteSpans;
  final int noteSpansRevision;
  final CanvasPenStyle pen;
  final RemoteStrokeDrafts? remoteDrafts;
  final bool selfBubbleHidden;
  final String? selfId;
  final CanvasShapeKind shapeKind;
  final CanvasPresenceTileOverrides tileOverrides;
  final CanvasViewMode? viewMode;
  final CanvasTool tool;
  final AppTokens tokens;
  final CanvasObjectMenuRequests menuRequests;
  final CanvasPresenceFrameResolver presenceFrames;

  /// The call tile whose feed fills the pane under the ink, if any.
  final String? focusedTileKey;

  @override
  Widget build(BuildContext context) => CanvasBoardKeys(
    document: document,
    tool: tool,
    onOpenActions: menuRequests.request,
    onPlaceNote: actions.onNotePlace,
    onPlaceShape: (world) => actions.onShapePlace(world, null),
    child: Stack(
      children: [
        // Below everything, including CanvasPresenceBackdrop - a grid line must never paint over a sent-to-back tile's own video, the bug this ordering fixes.
        CanvasGridLayer(
          document: document,
          line: tokens.borderSubtle,
          letterbox: tokens.surfaceSunken,
        ),
        if (focusedTileKey case final key?)
          CanvasFocusedFeed(
            document: document,
            tileKey: key,
            participants: callParticipants,
            cameraViewFor: actions.cameraViewFor,
            screenShareViewFor: actions.screenShareViewFor,
            onLost: () => actions.onFocusTile?.call(null),
          ),
        // Before CanvasSurface, so every tile's video sits under the ink, drafts and cursors; its controls stay in the layer above.
        CanvasPresenceBackdrop(
          document: document,
          participants: callParticipants,
          cameraViewFor: actions.cameraViewFor,
          screenShareViewFor: actions.screenShareViewFor,
          overrides: tileOverrides,
          hideSelfCamera: selfBubbleHidden,
          resolver: presenceFrames,
          focusedKey: focusedTileKey,
        ),
        CanvasSurface(
          document: document,
          ink: AppCanvasColors.annotation,
          inkColors: canvasPenInkByKey,
          penInk: pen.color,
          strokeWidth: pen.width,
          // AppTokens.stripe: its own doc reserves it for exactly this state.
          placeholderFill: tokens.stripe,
          placeholderIcon: tokens.textDisabled,
          // AppShadows.float: its own doc names a dragged canvas object as exactly what this token is for.
          elevationShadow: AppShadows.float,
          selectionOutline: tokens.accentFill,
          selectionHandleFill: tokens.surfaceRaised,
          selectionHandleBorder: tokens.accentFill,
          touchHandles: AppTouchTargets.of(context),
          noteColor: AppCanvasColors.note,
          shapeColor: AppCanvasColors.shape,
          noteTextInk: tokens.textPrimary,
          noteSpans: noteSpans,
          noteSpansRevision: noteSpansRevision,
          onStroke: actions.onStroke,
          tool: tool,
          onErase: actions.onErase,
          onEraseEnd: actions.onEraseEnd,
          onEraseCancel: actions.onEraseCancel,
          onSelectStart: actions.onSelectStart,
          onSelectDrag: actions.onSelectDrag,
          onSelectEnd: actions.onSelectEnd,
          onSelectCancel: actions.onSelectCancel,
          onSelectTap: actions.onSelectTap,
          onNotePlace: actions.onNotePlace,
          onShapePlace: actions.onShapePlace,
          shapeKind: shapeKind,
          cursors: cursors,
          cursorColors: cursorColors,
          cursorLabelFontFamily: AppFonts.sans,
          // Zero under reduce motion, which keeps the stepped positions.
          cursorGlide: AppMotion.reduced(context, cursorGlideDuration),
          onPointerMoved: actions.onPointerMoved,
          onPointerLeft: actions.onPointerLeft,
          remoteDrafts: remoteDrafts,
          onDraftPoint: actions.onDraftPoint,
          onDraftEnded: actions.onDraftEnded,
        ),
        CanvasObjectContextMenu(
          document: document,
          canManage: canManage,
          selfId: selfId,
          requests: menuRequests,
          tool: tool,
          onBringToFront: actions.onBringToFront,
          onSendToBack: actions.onSendToBack,
          onDeleteSelected: actions.onDeleteSelected,
          onPurge: actions.onPurge,
          onPasteImageAt: actions.onPasteImageAt,
          onAddNoteAt: actions.onNotePlace,
          onEditNote: actions.onEditNote,
          canDraw: !canvasErrorBlocksDrawing(error),
          onRecenter: actions.onRecenter,
        ),
        CanvasBoardObjectSemantics(
          document: document,
          onOpenActions: menuRequests.request,
        ),
        CanvasSelectionSemantics(
          document: document,
          onOpenActions: menuRequests.request,
        ),
        // Last, on top of CanvasObjectContextMenu's hit catcher - see canvas_presence_tile.dart's own doc for why a right-click on a tile is absorbed rather than reaching an object underneath it.
        FocusTraversalOrder(
          // After the board and the dock in Tab order; see canvas_pane_body.dart.
          order: const NumericFocusOrder(3),
          child: CanvasPresenceLayer(
            document: document,
            participants: callParticipants,
            overrides: tileOverrides,
            onCommit: actions.onCommitTile,
            onVideoInterest: actions.onVideoInterest,
            hideSelfCamera: selfBubbleHidden,
            tool: tool,
            participantMenuItemsBuilder: actions.participantMenuItemsBuilder,
            resolver: presenceFrames,
            focusedKey: focusedTileKey,
            onFocus: actions.onFocusTile,
            onPointerMoved: actions.onPointerMoved,
          ),
        ),
        ?noteEditor,
        // Topmost and non-interactive - see its own doc for why a pan or a tile drag stopping at worldLimit otherwise looks like nothing happened.
        CanvasWorldEdgeGlow(
          document: document,
          tileOverrides: tileOverrides,
          tokens: tokens,
        ),
        CanvasZoomIndicator(
          document: document,
          tokens: tokens,
          viewMode: viewMode,
          onFit: actions.onRecenter,
          onBringIn: actions.onBringIntoBoard,
        ),
      ],
    ),
  );
}
