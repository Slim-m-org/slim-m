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

import 'package:flutter/gestures.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'canvas_camera_wheel.dart';
import 'canvas_cursors.dart';
import 'canvas_document.dart';
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
part 'canvas_surface_gestures.dart';

/// A pen stroke the surface has finished and wants committed.
typedef StrokeCommitted = void Function(List<Offset> worldPoints);

/// A shape tool's placement: the box's own centre in world coordinates,
/// and, when the pointer actually dragged rather than merely tapped, the
/// world-space size that drag sized it to - null for a plain tap, which
/// keeps the caller's own default size.
typedef ShapePlaced = void Function(Offset worldCenter, Size? draggedSize);

/// This pointer moved to a world position, on every hover and drag alike.
/// The caller decides whether and how often to relay it.
typedef PointerMoved = void Function(Offset worldPoint);

/// A point was added to the pen stroke currently under this device's own
/// pointer, in world coordinates. Fires on the same down/move events
/// [StrokeCommitted] itself is eventually built from, but as they happen
/// rather than once at the end - the caller decides whether, and how often,
/// to relay it onward as an ephemeral preview.
typedef DraftPointAdded = void Function(Offset worldPoint);

/// Which gesture a single pointer draws.
///
/// Decision 0004 named the tool dock as exactly three placement tools - pen,
/// note, shape - each dropping a new object where a pointer taps. `eraser`
/// and `pan` are not placement modes: they act on objects already there
/// (erase, move, resize), added once this canvas grew objects worth acting
/// on, and are additional to the three named tools rather than a fourth and
/// fifth placement choice.
enum CanvasTool { pan, pen, note, shape, eraser }

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
    this.onSelectStart,
    this.onSelectDrag,
    this.onSelectEnd,
    this.onNotePlace,
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
    this.placeholderFill = const Color(0xFFB9C0C8),
    this.placeholderIcon = const Color(0xFF6C757E),
    this.elevationShadow = const [],
    this.selectionOutline,
    this.selectionHandleFill,
    this.selectionHandleBorder,
    this.noteColor,
    this.shapeColor,
    this.noteTextInk = const Color(0xFF1A1A1A),
    this.remoteDrafts,
    this.onDraftPoint,
    this.onDraftEnded,
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

  /// The selection outline and resize-handle colours. Null renders no
  /// selection layer at all, the same "pay nothing for it unwired" choice
  /// [cursors] already makes - a caller with no notion of selection (a test,
  /// a read-only viewer) does not pay for the extra paint pass.
  final Color? selectionOutline;
  final Color? selectionHandleFill;
  final Color? selectionHandleBorder;

  /// The muted fill and glyph colour for an image whose bytes could not be
  /// fetched or decoded. See [StrokePainter]'s own doc for why this draws
  /// something rather than nothing.
  final Color placeholderFill;
  final Color placeholderIcon;

  /// The shadow `StrokePainter` draws under whichever image
  /// `document.elevatedObjectId` currently names. Empty (the default) draws
  /// no elevation at all, the same "pay nothing for it unwired" choice
  /// [selectionOutline] already makes for a caller with no opinion.
  final List<BoxShadow> elevationShadow;
  final StrokeCommitted onStroke;
  final double strokeWidth;

  /// Other participants' live pointers, painted over the ink. Null renders
  /// no cursor layer at all, so a caller that has not wired remote cursors up
  /// yet (or a test that has no opinion about them) pays nothing for it.
  final CanvasCursors? cursors;

  /// How long a remote cursor glides to a newly-reported position, already
  /// passed through the caller's own reduce-motion gate (this package has no
  /// notion of one). Zero, the default, keeps the stepped behaviour; see
  /// [cursorGlideDuration] for the value the app passes and why. Read once
  /// when the surface first builds, like every other painter input here.
  final Duration cursorGlide;

  /// The closed colour set [cursors] indexes into. Meaningless without
  /// [cursors], and ignored when it is null.
  final List<Color> cursorColors;

  /// The app's own type family for a cursor's name chip. Null draws
  /// Flutter's platform default rather than the product's own type, the same
  /// reason [ink] and [cursorColors] arrive as plain values rather than this
  /// package reaching for a design system it does not depend on.
  final String? cursorLabelFontFamily;

  /// Fires on every hover or drag move, drawing or not, in world
  /// coordinates. The caller decides whether, and how often, to relay this
  /// onward - this widget applies no throttle of its own so a test can
  /// assert on every call without needing a fake clock.
  final PointerMoved? onPointerMoved;

  /// Other participants' in-flight strokes, painted between the committed
  /// ink and this device's own draft. Null renders no layer at all, the same
  /// "pay nothing for it unwired" shape [cursors] already uses.
  final RemoteStrokeDrafts? remoteDrafts;

  /// Fires on pointer-down (the first point) and every move while [tool] is
  /// [CanvasTool.pen] and a draft is under way. The caller decides whether,
  /// and how often, to relay this onward as an ephemeral preview.
  final DraftPointAdded? onDraftPoint;

  /// Fires once a pen draft ends - the pointer lifted, or a second pointer
  /// touched down and cancelled it - whether or not it went on to call
  /// [onStroke]. A caller relaying [onDraftPoint] should use this as the
  /// signal to tell other participants the gesture is over.
  final VoidCallback? onDraftEnded;

  /// Which gesture a pointer draws. Resolving a world point to an object is
  /// the caller's job, over [onErase], so this widget stays free of any
  /// notion of hit testing or permission.
  final CanvasTool tool;

  /// Fires once per pointer-down and again on every move while [tool] is
  /// [CanvasTool.eraser], so a drag can wipe through several objects the way
  /// a moderator clearing a defaced region expects. The pointer-down point
  /// itself is deferred exactly the way [onNotePlace]'s is (see
  /// `_pendingErasePoint`), so a pinch's bare first finger cancels rather
  /// than erasing whatever it happened to land on; every point after that is
  /// still live, since only the first sample can be a pinch's opening touch.
  final ValueChanged<Offset>? onErase;

  /// Fires once the whole erase gesture ends - the last pointer lifting,
  /// not the first of several in a multi-touch pan - so the caller can
  /// submit whatever [onErase] collected as one removal rather than one per
  /// point, which is what makes undoing an erase drag a single op.
  final VoidCallback? onEraseEnd;

  /// Fires on pointer-down while [tool] is [CanvasTool.pan], in world
  /// coordinates. Resolving whether an object was actually picked up (and
  /// which one) is the caller's job, the same division [onErase] already
  /// draws, so this widget carries no notion of hit testing either.
  final ValueChanged<Offset>? onSelectStart;

  /// Fires on every pointer move while [tool] is [CanvasTool.pan] and a
  /// drag is under way, in world coordinates.
  final ValueChanged<Offset>? onSelectDrag;

  /// Fires once a select-drag ends - the last pointer lifting - so the
  /// caller can commit the final position as one op rather than one per
  /// move, the same shape [onEraseEnd] already uses.
  final VoidCallback? onSelectEnd;

  /// Fires once for a tap while [tool] is [CanvasTool.note], at the point
  /// the pointer went down - a tap rather than a drag, since a note's box is
  /// a fixed default size the caller places and the person resizes it
  /// afterward with the select tool. Resolved on pointer-up, not
  /// pointer-down, so a second pointer touching down first (a pinch
  /// starting) can still cancel it - see [_resolvePendingPlacement].
  final ValueChanged<Offset>? onNotePlace;

  /// Fires once [tool] is [CanvasTool.shape] and every pointer has lifted -
  /// a tap places at the default size, the same deferred single-tap
  /// [onNotePlace] uses, for the same reason; a drag sizes the box itself,
  /// live-previewed by [shapeKind] while it is under way (see
  /// `DraftShape`'s own doc) and reported back through [ShapePlaced]'s own
  /// `draggedSize`.
  final ShapePlaced? onShapePlace;

  /// Which of [CanvasShapeKind] the next shape placement draws and
  /// previews - the bar's own current pick, forwarded here only so the
  /// live drag preview draws the right primitive; committing a shape is
  /// still entirely the caller's own job, over [onShapePlace].
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
  late final StrokePainter _strokes = StrokePainter(
    document: widget.document,
    ink: widget.ink,
    inkColors: widget.inkColors,
    noteColor: widget.noteColor,
    shapeColor: widget.shapeColor,
    textInk: widget.noteTextInk,
    textFontFamily: widget.cursorLabelFontFamily,
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
    if (oldWidget.penInk != widget.penInk ||
        oldWidget.strokeWidth != widget.strokeWidth) {
      _draftPainter = _buildDraftPainter();
    }
  }

  final DraftShape _shapeDraft = DraftShape();
  late final DraftShapePainter _shapeDraftPainter = DraftShapePainter(
    draft: _shapeDraft,
    document: widget.document,
    color: widget.shapeColor ?? widget.ink,
  );
  late final RemoteDraftPainter? _remoteDraftPainter =
      widget.remoteDrafts == null
          ? null
          : RemoteDraftPainter(
              drafts: widget.remoteDrafts!,
              document: widget.document,
              colors: widget.cursorColors,
            );
  late final CursorPainter? _cursorPainter = widget.cursors == null
      ? null
      : CursorPainter(
          cursors: widget.cursors!,
          document: widget.document,
          colors: widget.cursorColors,
          labelFontFamily: widget.cursorLabelFontFamily,
          glide: widget.cursorGlide,
          glideTick: _cursorGlideTick,
        );
  late final SelectionPainter? _selectionPainter = widget.selectionOutline ==
          null
      ? null
      : SelectionPainter(
          document: widget.document,
          outline: widget.selectionOutline!,
          handleFill: widget.selectionHandleFill ?? widget.selectionOutline!,
          handleBorder:
              widget.selectionHandleBorder ?? widget.selectionOutline!,
        );

  int _pointers = 0;

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
    widget.cursors?.removeListener(_onCursorsChanged);
    _cursorPainter?.disposeLabels();
    _strokes.disposeNoteLabels();
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
          onPointerCancel: _up,
          onPointerSignal: _signal,
          child: GestureDetector(
            onScaleStart: _scaleBegin,
            onScaleUpdate: _scaleUpdate,
            child: ValueListenableBuilder<bool>(
              valueListenable: _panning,
              builder: (context, panning, child) => MouseRegion(
                cursor: _cursorFor(widget.tool, widget.enabled, panning),
                child: child,
              ),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  RepaintBoundary(child: CustomPaint(painter: _strokes)),
                  if (_remoteDraftPainter case final remoteDraftPainter?)
                    RepaintBoundary(
                      child: CustomPaint(painter: remoteDraftPainter),
                    ),
                  RepaintBoundary(child: CustomPaint(painter: _draftPainter)),
                  RepaintBoundary(
                    child: CustomPaint(painter: _shapeDraftPainter),
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
