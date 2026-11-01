// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The drawing surface: several repaint boundaries, raw pointer input, and no
/// widget rebuild for anything the camera or a drag does. Grab-panning is
/// the one exception: starting or ending one rebuilds a single
/// `ValueListenableBuilder` around `MouseRegion` so its cursor can change,
/// never the painters or gesture layers it wraps - see `_panning`'s own doc.
///
/// The background lattice is `CanvasGridLayer`, a sibling widget mounted by
/// the caller rather than a layer of this widget's own stack - see that
/// file's own doc for why: this stack's opaque `MouseRegion` claims every
/// pointer within its bounds, so anything a caller mounts *behind* it (a
/// sent-to-back presence tile's own video, in the app layer) is painted
/// under this surface but never hit-tested again, and the grid used to sit
/// at the bottom of this same stack, drawing over exactly that content.
library;

import 'dart:async' show scheduleMicrotask;

import 'package:flutter/foundation.dart' show listEquals, mapEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'canvas_board_clip.dart';
import 'canvas_camera_wheel.dart';
import 'canvas_cursors.dart';
import 'canvas_document.dart';
import 'canvas_eraser_ring.dart';
import 'canvas_painters.dart';
import 'canvas_resize.dart' show minObjectSize;
import 'canvas_stroke_drafts.dart';
import 'selection_painter.dart';

/// Every pointer and scroll/scale handler `_CanvasSurfaceState.build` wires
/// up: split out once they pushed this file past the 500-line hard limit,
/// the same `part of` shape `canvas_document_selection.dart` already uses
/// for a class that grew a second cohesive group of methods rather than a
/// second class. The two fields a pinch gesture needs across its own start
/// and update callbacks (`_scaleStart`, `_scaleFocalWorld`) stay here, since
/// an extension cannot declare instance state.
part 'canvas_surface_camera_input.dart';
part 'canvas_surface_gestures.dart';
part 'canvas_surface_types.dart';
part 'canvas_surface_painters.dart';

/// The canvas itself.
///
/// Input is a raw [Listener] rather than a gesture recogniser for drawing:
/// a recogniser waits to see whether the gesture is something else, and the
/// design language is explicit that nothing under a live cursor may lag.
/// Panning and zooming go through [GestureDetector.onScaleUpdate], which only
/// takes over once a second pointer is down - and a second pointer cancels the
/// draft outright, so a two-finger pan cannot leave a stray mark.
class CanvasSurface extends StatefulWidget {
  const CanvasSurface({
    super.key,
    required this.document,
    required this.ink,
    required this.onStroke,
    this.onErase,
    this.onEraseEnd,
    this.onEraseCancel,
    this.onSelectStart,
    this.onSelectTap,
    this.onSelectDrag,
    this.onSelectEnd,
    this.onSelectCancel,
    this.onNotePlace,
    this.onTextPlace,
    this.onSelectLongPress,
    this.onShapePlace,
    this.shapeKind = CanvasShapeKind.rectangle,
    this.tool = CanvasTool.pen,
    this.strokeWidth = 3,
    this.penInk,
    this.inkColors = const {},
    this.enabled = true,
    this.cursors,
    this.cursorColors = const [],
    this.cursorLabelFontFamily,
    this.cursorGlide = Duration.zero,
    this.onPointerMoved,
    this.onPointerLeft,
    this.placeholderFill = const Color(0xFFB9C0C8),
    this.placeholderIcon = const Color(0xFF6C757E),
    this.elevationShadow = const [],
    this.selectionOutline,
    this.selectionHandleFill,
    this.selectionHandleBorder,
    this.touchHandles = false,
    this.noteColor,
    this.shapeColor,
    this.noteTextInk = const Color(0xFF1A1A1A),
    this.noteSpans,
    this.noteSpansRevision = 0,
    this.remoteDrafts,
    this.onDraftPoint,
    this.onDraftEnded,
    this.onDraftCancel,
  });

  final CanvasDocument document;
  final Color ink;

  /// What the pen draws its live preview in; null uses [ink]. Committed ink
  /// is painted from each stroke's own key through [inkColors].
  final Color? penInk;
  final Map<String, Color> inkColors;

  /// A note's own fill/border colour, and a shape's own outline colour.
  /// Null falls all the way back to [ink] - see [StrokePainter]'s own doc.
  final Color? noteColor;
  final Color? shapeColor;
  final Color noteTextInk;

  /// See [StrokePainter.noteSpans] and [StrokePainter.noteSpansRevision].
  final NoteSpanBuilder? noteSpans;
  final int noteSpansRevision;

  /// The selection outline and resize-handle colours; null renders no selection layer.
  final Color? selectionOutline;
  final Color? selectionHandleFill;
  final Color? selectionHandleBorder;

  /// Draws selection handles at the touch size.
  final bool touchHandles;

  /// The muted fill and glyph colour for an image whose bytes could not be fetched or decoded.
  final Color placeholderFill;
  final Color placeholderIcon;

  /// The shadow drawn under the image `document.elevatedObjectId` names; empty draws none.
  final List<BoxShadow> elevationShadow;
  final StrokeCommitted onStroke;
  final double strokeWidth;

  /// Other participants' live pointers, painted over the ink; null renders no cursor layer.
  final CanvasCursors? cursors;

  /// How long a remote cursor glides to a new position, already through the caller's reduce-motion gate; zero steps.
  final Duration cursorGlide;

  /// The closed colour set [cursors] indexes into. Meaningless without
  /// [cursors], and ignored when it is null.
  final List<Color> cursorColors;

  /// The app's type family for a cursor's name chip; null draws the platform default.
  final String? cursorLabelFontFamily;

  /// Fires on every hover or drag move in world coordinates; the caller throttles.
  final PointerMoved? onPointerMoved;

  /// The mouse left the surface, or a touch or pen lifted: nothing is under
  /// this pointer any more, so its cursor should disappear for others.
  final VoidCallback? onPointerLeft;

  /// Other participants' in-flight strokes, painted between the committed
  /// ink and this device's own draft. Null renders no layer at all, the same
  /// "pay nothing for it unwired" shape [cursors] already uses.
  final RemoteStrokeDrafts? remoteDrafts;

  /// Fires on pointer-down (the first point) and every move while [tool] is
  /// [CanvasTool.pen] and a draft is under way. The caller decides whether,
  /// and how often, to relay this onward as an ephemeral preview.
  final DraftPointAdded? onDraftPoint;

  /// Fires once a pen draft ends, whether or not it went on to call [onStroke].
  final VoidCallback? onDraftEnded;

  /// Fires when a draft is explicitly cancelled without committing ink.
  final VoidCallback? onDraftCancel;

  /// Which gesture a pointer draws. Resolving a world point to an object is
  /// the caller's job, over [onErase], so this widget stays free of any
  /// notion of hit testing or permission.
  final CanvasTool tool;

  /// Fires on pointer-down and every move while [tool] is [CanvasTool.eraser].
  /// The first point is deferred like [onNotePlace]'s (see `_pendingErasePoint`) so a pinch's first finger cancels instead of erasing.
  final ValueChanged<Offset>? onErase;

  /// Fires once the whole erase gesture ends, so the caller submits what [onErase] collected as one removal.
  final VoidCallback? onEraseEnd;

  /// Fires instead of [onEraseEnd] when the system cancels the erasing
  /// pointer, so the caller can bring back what the gesture hid.
  final VoidCallback? onEraseCancel;

  /// Fires on pointer-down while [tool] is [CanvasTool.pan]; the caller resolves which object, if any.
  final ValueChanged<Offset>? onSelectStart;

  /// Fires on every pointer move while [tool] is [CanvasTool.pan] and a
  /// drag is under way, in world coordinates.
  final ValueChanged<Offset>? onSelectDrag;

  /// Fires once a select-drag ends, so the caller commits the final position as one op.
  final VoidCallback? onSelectEnd;

  /// Fires instead of [onSelectEnd] when the system cancels the dragging
  /// pointer, so the caller can put the object back where it started.
  final VoidCallback? onSelectCancel;

  /// Fires after [onSelectEnd] for a select gesture that never travelled
  /// past a tap's slop, with the kind of pointer that made it, so the caller
  /// can tell a double click from a touch tap.
  final void Function(Offset world, PointerDeviceKind kind)? onSelectTap;

  /// Fires once for a tap while [tool] is [CanvasTool.note], at the point the pointer went down.
  /// Resolved on pointer-up so a second pointer (a pinch starting) can still cancel it - see [_resolvePendingPlacement].
  final ValueChanged<Offset>? onNotePlace;

  /// Fires like [onNotePlace] while [tool] is [CanvasTool.text]: a tap names where the text box goes.
  final ValueChanged<Offset>? onTextPlace;

  /// Fires after [onSelectEnd] for a select gesture a finger or pen held still past the long-press time, at the point it went down.
  final ValueChanged<Offset>? onSelectLongPress;

  /// Fires once [tool] is [CanvasTool.shape] and every pointer has lifted: a tap places the default size, a drag reports `draggedSize`.
  final ShapePlaced? onShapePlace;

  /// The shape kind the live drag preview draws; committing stays the caller's job over [onShapePlace].
  final CanvasShapeKind shapeKind;

  /// False freezes the pen and leaves pan and zoom alone, which is what a
  /// timed-out member gets: they keep seeing the canvas and cannot add to it.
  final bool enabled;

  @override
  State<CanvasSurface> createState() => _CanvasSurfaceState();
}

class _CanvasSurfaceState extends State<CanvasSurface>
    with SingleTickerProviderStateMixin {
  /// Bumped per frame while any cursor glide is in flight, so the cursor
  /// layer repaints between the roughly 80ms-apart frames the wire delivers.
  /// The ticker runs only from a cursor update until every glide lands -
  /// never while pointers are idle - and a zero [CanvasSurface.cursorGlide]
  /// (reduce motion, or a caller that never opted in) never starts it.
  final ValueNotifier<int> _cursorGlideTick = ValueNotifier<int>(0);

  /// Created in [initState], never lazily: a `late final` first touched in
  /// [dispose] (the zero-glide case, where nothing ever starts it) would run
  /// `createTicker`'s ancestor lookup after deactivation, which throws.
  late final Ticker _glideTicker;

  @override
  void initState() {
    super.initState();
    _glideTicker = createTicker(_onGlideFrame);
    widget.cursors?.addListener(_onCursorsChanged);
    widget.document.addListener(_onDocumentChanged);
  }

  /// Starts the glide ticker on a cursor update. The zero-glide early
  /// return is efficiency rather than correctness - without it the first
  /// tick's own stop check ends the ticker anyway, at the cost of one
  /// wasted frame per cursor update under reduce motion - which is why no
  /// behavioural test can see it and none pretends to.
  void _onCursorsChanged() {
    if (widget.cursorGlide <= Duration.zero) return;
    if (!_glideTicker.isActive) _glideTicker.start();
  }

  void _onGlideFrame(Duration elapsed) {
    _cursorGlideTick.value++;
    final cursors = widget.cursors;
    if (cursors == null ||
        !cursors.glidingAt(DateTime.now(), widget.cursorGlide)) {
      _glideTicker.stop();
    }
  }

  final DraftStroke _draft = DraftStroke();
  late StrokePainter _strokes = _buildStrokePainter();

  StrokePainter _buildStrokePainter() => StrokePainter(
        document: widget.document,
        ink: widget.ink,
        inkColors: widget.inkColors,
        noteColor: widget.noteColor,
        shapeColor: widget.shapeColor,
        textInk: widget.noteTextInk,
        textFontFamily: widget.cursorLabelFontFamily,
        noteSpans: widget.noteSpans,
        noteSpansRevision: widget.noteSpansRevision,
        placeholderFill: widget.placeholderFill,
        placeholderIcon: widget.placeholderIcon,
        elevationShadow: widget.elevationShadow,
      );
  late DraftPainter _draftPainter = _buildDraftPainter();

  DraftPainter _buildDraftPainter() => DraftPainter(
        draft: _draft,
        document: widget.document,
        ink: widget.penInk ?? widget.ink,
        width: widget.strokeWidth,
      );

  @override
  void didUpdateWidget(CanvasSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    _refreshPainters(oldWidget);
    if (oldWidget.document != widget.document) {
      oldWidget.document.removeListener(_onDocumentChanged);
      widget.document.addListener(_onDocumentChanged);
    }
    if (oldWidget.tool != widget.tool || !widget.enabled) {
      _endGestureAfterBuild();
    }
  }

  /// Closes the running gesture once this build is over: its callbacks rebuild ancestors, which a build must not.
  void _endGestureAfterBuild() {
    if (_gesture == null) return;
    scheduleMicrotask(_finishGesture);
  }

  final DraftShape _shapeDraft = DraftShape();
  late DraftShapePainter _shapeDraftPainter = _buildShapeDraftPainter();

  DraftShapePainter _buildShapeDraftPainter() => DraftShapePainter(
        draft: _shapeDraft,
        document: widget.document,
        color: widget.shapeColor ?? widget.ink,
      );
  late RemoteDraftPainter? _remoteDraftPainter = _buildRemoteDraftPainter();

  RemoteDraftPainter? _buildRemoteDraftPainter() => widget.remoteDrafts == null
      ? null
      : RemoteDraftPainter(
          drafts: widget.remoteDrafts!,
          document: widget.document,
          colors: widget.cursorColors,
          ink: widget.ink,
          inkColors: widget.inkColors,
        );
  late CursorPainter? _cursorPainter = _buildCursorPainter();

  CursorPainter? _buildCursorPainter() => widget.cursors == null
      ? null
      : CursorPainter(
          cursors: widget.cursors!,
          document: widget.document,
          colors: widget.cursorColors,
          labelFontFamily: widget.cursorLabelFontFamily,
          glide: widget.cursorGlide,
          glideTick: _cursorGlideTick,
        );
  late SelectionPainter? _selectionPainter = _buildSelectionPainter();

  SelectionPainter? _buildSelectionPainter() => widget.selectionOutline == null
      ? null
      : SelectionPainter(
          document: widget.document,
          outline: widget.selectionOutline!,
          handleFill: widget.selectionHandleFill ?? widget.selectionOutline!,
          handleBorder:
              widget.selectionHandleBorder ?? widget.selectionOutline!,
          touchHandles: widget.touchHandles,
        );

  /// The pointers taking part in a gesture; a right-click or a rejected palm never joins.
  final Map<int, PointerDeviceKind> _downPointers = {};
  final Set<int> _stylusPointers = <int>{};
  _Gesture? _gesture;

  /// True while a callback this gesture made may be moving the camera itself.
  bool _inOwnCallback = false;

  /// Where the select tool's pointer went down, until it moves past a tap's
  /// slop or a second pointer joins.
  Offset? _selectDownAt;

  /// A note or shape placement [_down] armed, resolved only once every
  /// pointer has lifted - see [_resolvePendingPlacement]. Needed because
  /// panning and zooming here are two-pointer-only ([_scaleUpdate]'s own
  /// guard), so a pinch always starts as one finger down alone.
  CanvasTool? _pendingPlacementTool;
  Offset? _pendingPlacementWorld;

  /// The eraser's own pointer-down point, held back for exactly the same
  /// reason [_pendingPlacementWorld] is: at `_down` time there is no way yet
  /// to tell a real one-finger erase from the first touch of a pinch. A
  /// second pointer landing discards it in [_down] itself, immediately,
  /// rather than waiting for `_up` the way a placement does - the eraser
  /// needs no [_pointers]-zero check on release, since [_move] or a
  /// pointer-up with nothing else down are both proof a pinch never started.
  Offset? _pendingErasePoint;

  /// Whether a middle-mouse-button drag is currently panning the camera -
  /// see `canvas_surface_gestures.dart`'s own doc for why this is a
  /// [ValueNotifier] the cursor alone listens to rather than a plain field:
  /// entering or leaving a grab needs the [MouseRegion] to show a different
  /// cursor, and this is the one place that happens without rebuilding the
  /// painters and gesture layers underneath it.
  final ValueNotifier<bool> _panning = ValueNotifier<bool>(false);

  /// The screen point the last pan update moved from, so only the delta
  /// since that point is applied rather than a jump to the raw position.
  Offset? _panFrom;

  /// Which pointer's grab started the current pan, so an unrelated second
  /// pointer's own up (or move) cannot end or steer it - see `_beginPan`'s
  /// own doc for why `_panning` alone is not enough to answer that.
  int? _panPointer;

  @override
  void dispose() {
    widget.document.removeListener(_onDocumentChanged);
    widget.cursors?.removeListener(_onCursorsChanged);
    _cursorPainter?.disposeLabels();
    _strokes.dispose();
    // Before super: the ticker mixin asserts nothing is still ticking.
    _glideTicker.dispose();
    _cursorGlideTick.dispose();
    _draft.dispose();
    _shapeDraft.dispose();
    _panning.dispose();
    super.dispose();
  }

  Camera? _scaleStart;
  Offset? _scaleFocalWorld;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        // Outside the paint pass on purpose: setting it during paint would mutate what is being painted.
        WidgetsBinding.instance.addPostFrameCallback(
          (_) => widget.document.setViewport(size),
        );
        return Listener(
          onPointerDown: _down,
          onPointerMove: _move,
          onPointerHover: _hover,
          onPointerUp: _up,
          onPointerCancel: _cancel,
          onPointerSignal: _signal,
          child: GestureDetector(
            onScaleStart: _scaleBegin,
            onScaleUpdate: _scaleUpdate,
            child: ValueListenableBuilder<bool>(
              valueListenable: _panning,
              builder: (context, panning, child) => MouseRegion(
                cursor: _cursorFor(widget.tool, widget.enabled, panning),
                onExit: (_) => widget.onPointerLeft?.call(),
                child: CanvasEraserRing(
                  active: widget.tool == CanvasTool.eraser &&
                      widget.enabled &&
                      !panning,
                  child: child!,
                ),
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CanvasBoardClip(
                    document: widget.document,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        RepaintBoundary(child: CustomPaint(painter: _strokes)),
                        if (_remoteDraftPainter case final remoteDraftPainter?)
                          RepaintBoundary(
                            child: CustomPaint(painter: remoteDraftPainter),
                          ),
                        RepaintBoundary(
                            child: CustomPaint(painter: _draftPainter)),
                        RepaintBoundary(
                          child: CustomPaint(painter: _shapeDraftPainter),
                        ),
                      ],
                    ),
                  ),
                  if (_selectionPainter case final selectionPainter?)
                    RepaintBoundary(
                      child: CustomPaint(painter: selectionPainter),
                    ),
                  if (_cursorPainter case final cursorPainter?)
                    RepaintBoundary(child: CustomPaint(painter: cursorPainter)),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
