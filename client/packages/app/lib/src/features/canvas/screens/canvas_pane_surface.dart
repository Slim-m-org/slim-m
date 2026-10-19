// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's drawing layers, bottom to top: grid, call-tile backdrop,
/// ink surface, object menu, call tiles, note editor and edge indicators.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_forbidden_message.dart';
import 'canvas_object_context_menu.dart';
import 'canvas_pane_body.dart';
import 'canvas_pen_style.dart';
import 'canvas_presence_frame.dart';
import 'canvas_presence_layer.dart';
import 'canvas_selection_semantics.dart';
import 'canvas_world_edge_glow.dart';
import 'canvas_zoom_indicator.dart';

/// Lays out the layers from [pane]'s own configuration, so the pane body does
/// not re-declare the forty callbacks it only forwards.
class CanvasPaneSurface extends StatelessWidget {
  const CanvasPaneSurface({
    super.key,
    required this.pane,
    required this.tokens,
    required this.menuRequests,
    required this.presenceFrames,
  });

  final CanvasPaneBody pane;
  final AppTokens tokens;
  final CanvasObjectMenuRequests menuRequests;
  final CanvasPresenceFrameResolver presenceFrames;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Below everything, including CanvasPresenceBackdrop - a grid line must never paint over a sent-to-back tile's own video, the bug this ordering fixes.
      CanvasGridLayer(
        document: pane.document,
        line: tokens.borderSubtle,
        letterbox: tokens.surfaceSunken,
      ),
      // Before CanvasSurface, so a sent-to-back tile's own pixels sit under real ink - see canvas_presence_layer.dart's own doc for why its controls stay in the layer below regardless.
      CanvasPresenceBackdrop(
        document: pane.document,
        participants: pane.callParticipants,
        cameraViewFor: pane.cameraViewFor,
        screenShareViewFor: pane.screenShareViewFor,
        overrides: pane.tileOverrides,
        hideSelfCamera: pane.selfBubbleHidden,
        resolver: presenceFrames,
      ),
      CanvasSurface(
        document: pane.document,
        ink: AppCanvasColors.annotation,
        inkColors: canvasPenInkByKey,
        penInk: pane.pen.color,
        strokeWidth: pane.pen.width,
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
        noteSpans: pane.noteSpans,
        noteSpansRevision: pane.noteSpansRevision,
        onStroke: pane.onStroke,
        tool: pane.tool,
        onErase: pane.onErase,
        onEraseEnd: pane.onEraseEnd,
        onSelectStart: pane.onSelectStart,
        onSelectDrag: pane.onSelectDrag,
        onSelectEnd: pane.onSelectEnd,
        onSelectTap: pane.onSelectTap,
        onNotePlace: pane.onNotePlace,
        onShapePlace: pane.onShapePlace,
        shapeKind: pane.shapeKind,
        cursors: pane.cursors,
        cursorColors: pane.cursorColors,
        cursorLabelFontFamily: AppFonts.sans,
        // Zero under reduce motion, which keeps the stepped positions.
        cursorGlide: AppMotion.reduced(context, cursorGlideDuration),
        onPointerMoved: pane.onPointerMoved,
        onPointerLeft: pane.onPointerLeft,
        remoteDrafts: pane.remoteDrafts,
        onDraftPoint: pane.onDraftPoint,
        onDraftEnded: pane.onDraftEnded,
      ),
      CanvasObjectContextMenu(
        document: pane.document,
        canManage: pane.canManage,
        selfId: pane.selfId,
        requests: menuRequests,
        tool: pane.tool,
        onToolChanged: pane.onToolChanged,
        onBringToFront: pane.onBringToFront,
        onSendToBack: pane.onSendToBack,
        onDeleteSelected: pane.onDeleteSelected,
        onPasteImageAt: pane.onPasteImageAt,
        onAddNoteAt: pane.onNotePlace,
        onEditNote: pane.onEditNote,
        canDraw: !canvasErrorBlocksDrawing(pane.error),
        onRecenter: pane.onRecenter,
      ),
      CanvasSelectionSemantics(
        document: pane.document,
        onOpenActions: menuRequests.request,
      ),
      // Last, on top of CanvasObjectContextMenu's hit catcher - see canvas_presence_tile.dart's own doc for why a right-click on a tile is absorbed rather than reaching an object underneath it.
      CanvasPresenceLayer(
        document: pane.document,
        participants: pane.callParticipants,
        cameraViewFor: pane.cameraViewFor,
        screenShareViewFor: pane.screenShareViewFor,
        overrides: pane.tileOverrides,
        onCommit: pane.onCommitTile,
        onVideoInterest: pane.onVideoInterest,
        hideSelfCamera: pane.selfBubbleHidden,
        tool: pane.tool,
        participantMenuItemsBuilder: pane.participantMenuItemsBuilder,
        resolver: presenceFrames,
      ),
      ?pane.noteEditor,
      // Topmost and non-interactive - see its own doc for why a pan or a tile drag stopping at worldLimit otherwise looks like nothing happened.
      CanvasWorldEdgeGlow(
        document: pane.document,
        tileOverrides: pane.tileOverrides,
        tokens: tokens,
      ),
      CanvasZoomIndicator(
        document: pane.document,
        tokens: tokens,
        onFit: pane.onRecenter,
        onBringIn: pane.onBringIntoBoard,
      ),
    ],
  );
}
