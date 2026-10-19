// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The canvas pane's drawing layers, bottom to top: grid, call-tile backdrop,
/// ink surface, object menu, call tiles, note editor and edge indicators.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';
import 'package:slimm_rtc/rtc.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

import 'canvas_forbidden_message.dart';
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
    required this.tool,
    required this.tokens,
    required this.menuRequests,
    required this.presenceFrames,
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
  final CanvasTool tool;
  final AppTokens tokens;
  final CanvasObjectMenuRequests menuRequests;
  final CanvasPresenceFrameResolver presenceFrames;

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      // Below everything, including CanvasPresenceBackdrop - a grid line must never paint over a sent-to-back tile's own video, the bug this ordering fixes.
      CanvasGridLayer(
        document: document,
        line: tokens.borderSubtle,
        letterbox: tokens.surfaceSunken,
      ),
      // Before CanvasSurface, so a sent-to-back tile's own pixels sit under real ink - see canvas_presence_layer.dart's own doc for why its controls stay in the layer below regardless.
      CanvasPresenceBackdrop(
        document: document,
        participants: callParticipants,
        cameraViewFor: actions.cameraViewFor,
        screenShareViewFor: actions.screenShareViewFor,
        overrides: tileOverrides,
        hideSelfCamera: selfBubbleHidden,
        resolver: presenceFrames,
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
        onSelectStart: actions.onSelectStart,
        onSelectDrag: actions.onSelectDrag,
        onSelectEnd: actions.onSelectEnd,
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
        onToolChanged: actions.onToolChanged,
        onBringToFront: actions.onBringToFront,
        onSendToBack: actions.onSendToBack,
        onDeleteSelected: actions.onDeleteSelected,
        onPasteImageAt: actions.onPasteImageAt,
        onAddNoteAt: actions.onNotePlace,
        onEditNote: actions.onEditNote,
        canDraw: !canvasErrorBlocksDrawing(error),
        onRecenter: actions.onRecenter,
      ),
      CanvasSelectionSemantics(
        document: document,
        onOpenActions: menuRequests.request,
      ),
      // Last, on top of CanvasObjectContextMenu's hit catcher - see canvas_presence_tile.dart's own doc for why a right-click on a tile is absorbed rather than reaching an object underneath it.
      CanvasPresenceLayer(
        document: document,
        participants: callParticipants,
        cameraViewFor: actions.cameraViewFor,
        screenShareViewFor: actions.screenShareViewFor,
        overrides: tileOverrides,
        onCommit: actions.onCommitTile,
        onVideoInterest: actions.onVideoInterest,
        hideSelfCamera: selfBubbleHidden,
        tool: tool,
        participantMenuItemsBuilder: actions.participantMenuItemsBuilder,
        resolver: presenceFrames,
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
        onFit: actions.onRecenter,
        onBringIn: actions.onBringIntoBoard,
      ),
    ],
  );
}
