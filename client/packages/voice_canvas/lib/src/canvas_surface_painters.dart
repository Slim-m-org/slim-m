// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The surface's painters, one per layer. Each gets a new instance when the
/// colours it was built with change, so a theme switch reaches committed ink,
/// cursors and selection, not only the draft; an unchanged theme keeps every
/// painter and its caches.
library;

import 'package:flutter/foundation.dart';

import 'canvas_painters.dart';
import 'canvas_surface.dart';
import 'selection_painter.dart';

class CanvasSurfacePainters {
  CanvasSurfacePainters(
    CanvasSurface surface, {
    required DraftStroke draft,
    required DraftShape shapeDraft,
    required ValueNotifier<int> glideTick,
  })  : _draftStroke = draft,
        _draftShape = shapeDraft,
        _glideTick = glideTick {
    _strokes = _buildStrokes(surface);
    _draft = _buildDraft(surface);
    _shapeDraft = _buildShapeDraft(surface);
    _remoteDrafts = _buildRemoteDrafts(surface);
    _cursors = _buildCursors(surface);
    _selection = _buildSelection(surface);
  }

  final DraftStroke _draftStroke;
  final DraftShape _draftShape;
  final ValueNotifier<int> _glideTick;
  late StrokePainter _strokes;
  late DraftPainter _draft;
  late DraftShapePainter _shapeDraft;
  late RemoteDraftPainter? _remoteDrafts;
  late CursorPainter? _cursors;
  late SelectionPainter? _selection;
  double? _devicePixelRatio;

  StrokePainter get strokes => _strokes;
  DraftPainter get draft => _draft;
  DraftShapePainter get shapeDraft => _shapeDraft;

  /// Null when the surface has no remote drafts to paint.
  RemoteDraftPainter? get remoteDrafts => _remoteDrafts;

  /// Null when the surface has no cursors to paint.
  CursorPainter? get cursors => _cursors;

  /// Null when the surface has no selection outline colour.
  SelectionPainter? get selection => _selection;

  /// Gives committed ink a texture at [ratio], as sharp as the live ink on the screen it is now on.
  void setDevicePixelRatio(CanvasSurface w, double ratio) {
    if (_strokes.devicePixelRatio == ratio) return;
    _strokes.dispose();
    _devicePixelRatio = ratio;
    _strokes = _buildStrokes(w);
  }

  /// Rebuilds each painter whose inputs differ between [o] and [w].
  void refresh(CanvasSurface o, CanvasSurface w) {
    final documentChanged = o.document != w.document;
    if (documentChanged ||
        o.penInk != w.penInk ||
        o.strokeWidth != w.strokeWidth) {
      _draft = _buildDraft(w);
    }
    if (documentChanged ||
        o.ink != w.ink ||
        !mapEquals(o.inkColors, w.inkColors) ||
        o.noteColor != w.noteColor ||
        o.shapeColor != w.shapeColor ||
        o.noteTextInk != w.noteTextInk ||
        o.noteSpansRevision != w.noteSpansRevision ||
        o.cursorLabelFontFamily != w.cursorLabelFontFamily ||
        o.placeholderFill != w.placeholderFill ||
        o.placeholderIcon != w.placeholderIcon ||
        o.elevationShadow != w.elevationShadow) {
      _strokes.dispose();
      _strokes = _buildStrokes(w);
    }
    if (documentChanged || o.shapeColor != w.shapeColor || o.ink != w.ink) {
      _shapeDraft = _buildShapeDraft(w);
    }
    final colorsChanged = !listEquals(o.cursorColors, w.cursorColors);
    if (documentChanged ||
        colorsChanged ||
        o.remoteDrafts != w.remoteDrafts ||
        o.ink != w.ink ||
        !mapEquals(o.inkColors, w.inkColors)) {
      _remoteDrafts = _buildRemoteDrafts(w);
    }
    if (documentChanged ||
        colorsChanged ||
        o.cursors != w.cursors ||
        o.cursorGlide != w.cursorGlide ||
        o.cursorLabelFontFamily != w.cursorLabelFontFamily) {
      _cursors?.disposeLabels();
      _cursors = _buildCursors(w);
    }
    if (documentChanged ||
        o.selectionOutline != w.selectionOutline ||
        o.selectionHandleFill != w.selectionHandleFill ||
        o.selectionHandleBorder != w.selectionHandleBorder ||
        o.touchHandles != w.touchHandles) {
      _selection = _buildSelection(w);
    }
  }

  void dispose() {
    _cursors?.disposeLabels();
    _strokes.dispose();
  }

  StrokePainter _buildStrokes(CanvasSurface w) {
    final painter = _newStrokes(w);
    if (_devicePixelRatio case final ratio?) painter.devicePixelRatio = ratio;
    return painter;
  }

  StrokePainter _newStrokes(CanvasSurface w) => StrokePainter(
        document: w.document,
        ink: w.ink,
        inkColors: w.inkColors,
        noteColor: w.noteColor,
        shapeColor: w.shapeColor,
        textInk: w.noteTextInk,
        textFontFamily: w.cursorLabelFontFamily,
        noteSpans: w.noteSpans,
        noteSpansRevision: w.noteSpansRevision,
        placeholderFill: w.placeholderFill,
        placeholderIcon: w.placeholderIcon,
        elevationShadow: w.elevationShadow,
      );

  DraftPainter _buildDraft(CanvasSurface w) => DraftPainter(
        draft: _draftStroke,
        document: w.document,
        ink: w.penInk ?? w.ink,
        width: w.strokeWidth,
      );

  DraftShapePainter _buildShapeDraft(CanvasSurface w) => DraftShapePainter(
        draft: _draftShape,
        document: w.document,
        color: w.shapeColor ?? w.ink,
      );

  RemoteDraftPainter? _buildRemoteDrafts(CanvasSurface w) =>
      w.remoteDrafts == null
          ? null
          : RemoteDraftPainter(
              drafts: w.remoteDrafts!,
              document: w.document,
              colors: w.cursorColors,
              ink: w.ink,
              inkColors: w.inkColors,
            );

  CursorPainter? _buildCursors(CanvasSurface w) => w.cursors == null
      ? null
      : CursorPainter(
          cursors: w.cursors!,
          document: w.document,
          colors: w.cursorColors,
          labelFontFamily: w.cursorLabelFontFamily,
          glide: w.cursorGlide,
          glideTick: _glideTick,
        );

  SelectionPainter? _buildSelection(CanvasSurface w) =>
      w.selectionOutline == null
          ? null
          : SelectionPainter(
              document: w.document,
              outline: w.selectionOutline!,
              handleFill: w.selectionHandleFill ?? w.selectionOutline!,
              handleBorder: w.selectionHandleBorder ?? w.selectionOutline!,
              touchHandles: w.touchHandles,
            );
}
