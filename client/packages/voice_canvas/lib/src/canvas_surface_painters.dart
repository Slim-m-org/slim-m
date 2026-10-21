// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
part of 'canvas_surface.dart';

/// Hands each painter a new instance when the colours it was built with
/// change, so a theme switch reaches committed ink, cursors and selection,
/// not only the draft; an unchanged theme keeps every painter and its caches.
extension _CanvasSurfacePainters on _CanvasSurfaceState {
  void _refreshPainters(CanvasSurface o) {
    final w = widget;
    if (o.penInk != w.penInk || o.strokeWidth != w.strokeWidth) {
      _draftPainter = _buildDraftPainter();
    }
    if (o.ink != w.ink ||
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
      _strokes = _buildStrokePainter();
    }
    if (o.shapeColor != w.shapeColor || o.ink != w.ink) {
      _shapeDraftPainter = _buildShapeDraftPainter();
    }
    if (!listEquals(o.cursorColors, w.cursorColors) ||
        o.cursorLabelFontFamily != w.cursorLabelFontFamily) {
      _remoteDraftPainter = _buildRemoteDraftPainter();
      _cursorPainter?.disposeLabels();
      _cursorPainter = _buildCursorPainter();
    }
    if (o.selectionOutline != w.selectionOutline ||
        o.selectionHandleFill != w.selectionHandleFill ||
        o.selectionHandleBorder != w.selectionHandleBorder ||
        o.touchHandles != w.touchHandles) {
      _selectionPainter = _buildSelectionPainter();
    }
  }
}
