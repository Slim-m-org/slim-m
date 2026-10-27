// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scene contract: how slim turns a module's opaque output string into
/// something it can paint, without slim or the module knowing anything about
/// each other's internals.
///
/// A module returns a plain string (module ABI v1 has no content type). When
/// that string parses as a JSON object tagged `"$slim": "scene/1"`, slim reads
/// it as a scene and paints it (see `module_scene_painter.dart`) instead of
/// showing the raw text; anything else stays plain text exactly as before. So
/// this is a client-side reading of an ordinary string, not a wire change: a
/// module opts in simply by choosing to emit one.
///
/// Colours are named, not baked: an op may name a theme token (`accent`,
/// `surface`, `sunken`, `muted`, `text`, `border`, `danger`) and the painter
/// resolves it against the viewer's theme, so a module's drawing looks native
/// in light and dark alike without the module knowing which is in force. A
/// literal `#rrggbb` still passes through untouched.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect;

export 'module_scene_parse.dart' show parseModuleScene;
export 'module_scene_types.dart';
export 'module_scene_sweep.dart' show SceneSweep;

import 'module_scene_path.dart';
import 'module_scene_sweep.dart';
import 'module_scene_types.dart';

/// One drawing primitive. Coordinates are in the scene's own logical units
/// ([ModuleScene.width] by [ModuleScene.height]); the painter scales them to
/// whatever box it is given.
sealed class SceneOp {
  const SceneOp();
}

/// A colour grid: [data] is one character per cell, row-major, each a palette
/// index (`'0'`..). The workhorse behind boards, heatmaps and automata. A
/// non-null [tap] makes a tapped cell report `"$tap:row,col"`.
class CellsOp extends SceneOp {
  const CellsOp({
    required this.cols,
    required this.rows,
    required this.data,
    required this.palette,
    this.gap = 0,
    this.tap,
    this.tapBatch = false,
    this.box,
  });

  /// The most cells one axis may ask for, clamped at parse like every other
  /// ceiling in this contract.
  ///
  /// Two measurements meet here. At a phone's ~390 logical points a 128-column
  /// grid gives each cell about 3 points, and below that a cell stops being
  /// something a person can see or aim at, so a bigger grid is not a grid any
  /// more. And one paint of 128x128 measured 2.5ms on the machine this was
  /// written on against 10.4ms for 256x256 - a phone is several times slower
  /// again, which puts 256 outside a frame while 128 stays inside one.
  ///
  /// 128 is also 2.6x the largest grid any shipped module asks for
  /// (game-of-life's 48x48; connect-four is 7x6, music-box 16x8), so the
  /// ceiling is well clear of real use rather than shaped around it.
  ///
  /// `data` already bounds the painter's work - it draws no more cells than
  /// characters it was sent - so this is a robustness ceiling rather than a
  /// fix for a live hang. That is the point: "it happens to be bounded by the
  /// module output size limit" is a guarantee that stops being true the moment
  /// that unrelated limit moves.
  static const maxPerAxis = 128;

  final int cols;
  final int rows;
  final String data;
  final List<String> palette;
  final double gap;
  final String? tap;

  /// Where the grid sits, in scene units, or null for the whole scene.
  ///
  /// Null is what every module written before this could rely on, and stays
  /// the default: a grid was the scene. Naming a box lets one be a part of a
  /// scene instead, next to labels, buttons or other art - which the
  /// `music-box` module wanted and worked around by shading every fourth
  /// column, because nothing can be drawn between a full-scene grid's cells.
  ///
  /// Both the painting and the hit test read this, so a tap outside the box
  /// falls through to whatever op is underneath rather than being claimed by a
  /// grid that is not there.
  final SceneBox? box;

  /// Whether this module reads several cells from one [tap] action, as a
  /// `;`-separated list.
  ///
  /// A module call is a round trip and only one runs at a time, so a drag
  /// across a grid costs a call per cell without this. Defaults false because
  /// an older module would answer "bad cell" to a list, so a client may only
  /// send one to a module that has said it can read one. Additive both ways:
  /// a module that declares it still accepts a list of one, which is what a
  /// client that never looks at this field keeps sending.
  final bool tapBatch;
}

class RectOp extends SceneOp {
  const RectOp({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    this.fill,
    this.gradient,
    this.stroke,
    this.strokeWidth = 1,
    this.radius = 0,
    this.tap,
    this.sweep,
  });

  final double x;
  final double y;
  final double w;
  final double h;
  final String? fill;

  /// Wins over [fill] when both are set. A module that sends both has said two
  /// things about one surface, and the richer one is the one it meant.
  final SceneGradient? gradient;
  final String? stroke;
  final double strokeWidth;
  final double radius;
  final String? tap;

  /// Motion the client plays across this op; see `module_scene_sweep.dart`.
  final SceneSweep? sweep;
}

class CircleOp extends SceneOp {
  const CircleOp({
    required this.cx,
    required this.cy,
    required this.r,
    this.fill,
    this.gradient,
    this.stroke,
    this.strokeWidth = 1,
    this.tap,
    this.sweep,
  });

  final double cx;
  final double cy;
  final double r;
  final String? fill;

  /// See [RectOp.gradient].
  final SceneGradient? gradient;
  final String? stroke;
  final double strokeWidth;
  final String? tap;

  /// Motion the client plays across this op; see `module_scene_sweep.dart`.
  final SceneSweep? sweep;
}

class LineOp extends SceneOp {
  const LineOp({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    this.stroke,
    this.strokeWidth = 1,
    this.sweep,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;
  final String? stroke;
  final double strokeWidth;

  /// Motion the client plays across this op; see `module_scene_sweep.dart`.
  final SceneSweep? sweep;
}

/// An arbitrary shape, from an SVG-style `d` string. The op that stops the
/// contract capping a drawing at rectangles and circles: anything a module can
/// describe with lines and beziers, it can now draw.
///
/// [steps] is already parsed and already bounded (see [sceneMaxPathSteps]), so
/// the painter walks a fixed list rather than a string.
class PathOp extends SceneOp {
  const PathOp({
    required this.steps,
    this.fill,
    this.stroke,
    this.strokeWidth = 1,
    this.tap,
  });

  final List<ScenePathStep> steps;
  final String? fill;
  final String? stroke;
  final double strokeWidth;

  /// Hit-tested against the filled shape, so a tappable path wants a [fill];
  /// an unfilled outline has almost no interior to land in.
  final String? tap;
}

class TextOp extends SceneOp {
  const TextOp({
    required this.x,
    required this.y,
    required this.text,
    this.fill,
    this.size = 12,
    this.align = 'left',
    this.sweep,
  });

  final double x;
  final double y;
  final String text;
  final String? fill;
  final double size;
  final String align;

  /// Motion the client plays across this op; see `module_scene_sweep.dart`.
  final SceneSweep? sweep;
}

/// A raster image, carried inside the scene as base64.
///
/// The last gap decision 0021 named, and the only op whose cost is set by how
/// much a module chose to send rather than by anything slim decided, so it is
/// the one with a byte ceiling rather than a count.
///
/// [bytes] is already decoded from base64 and already under
/// [maxEncodedLength]; a payload over that is dropped at parse rather than
/// handed on, because the point of a ceiling is that nothing downstream ever
/// holds an oversized one. Turning those bytes into something paintable is a
/// separate, asynchronous step - see `module_scene_images.dart` - because a
/// `CustomPainter` cannot await a decode.
///
/// [key] identifies these bytes for that cache, so a module re-emitting the
/// same image on every frame decodes it once. It is a digest of the bytes, not
/// a cryptographic hash: a collision would show one of this module's own
/// pictures in place of another, which is a rendering bug and not a boundary
/// being crossed.
class ImageOp extends SceneOp {
  const ImageOp({
    required this.x,
    required this.y,
    required this.w,
    required this.h,
    required this.bytes,
    required this.key,
    this.tap,
  });

  final double x;
  final double y;
  final double w;
  final double h;
  final Uint8List bytes;
  final int key;
  final String? tap;

  /// How long the base64 string may be.
  ///
  /// Checked before decoding, so an oversized payload costs a length comparison
  /// rather than an allocation. 88k of base64 is about 64k of image: a sprite,
  /// an icon, a small chart - enough to be useful and far too small to be a
  /// photograph. A scene is a message attachment's neighbour, not its
  /// replacement; a module with a real picture to show should be posting one.
  static const maxEncodedLength = 88 * 1024;

  /// How many images one scene may carry.
  ///
  /// Each one is a decode, and a decode is the most expensive thing a scene can
  /// ask a client to do. Eight is a sprite sheet's worth; a scene wanting a
  /// hundred is a scene that should be one image.
  static const maxPerScene = 8;
}

/// A text entry region. The op that makes a scene answerable in words rather
/// than only in taps: a guess, a name, a formula, a search.
///
/// The module declares where the field sits and how wide it is, and slim
/// decides how tall. A module cannot describe a control that looks native at an
/// arbitrary height, and a text field that does not look like the rest of the
/// app is worse than one an op could not place precisely.
///
/// [value] is the module's: whatever comes back in the next scene is what the
/// field shows, so a module can correct, clear or reformat what was typed. A
/// submission arrives as the action `"<submit>:<text>"`, the same
/// colon-separated shape a tapped cell already uses.
class InputOp extends SceneOp {
  const InputOp({
    required this.x,
    required this.y,
    required this.w,
    required this.submit,
    this.value = '',
    this.placeholder,
    this.maxLength = defaultMaxLength,
  });

  final double x;
  final double y;
  final double w;

  /// The action name a submission is reported under.
  final String submit;

  final String value;
  final String? placeholder;

  /// How much may be typed. Bounded because the text rides back to the module
  /// on every submission and a module should not be able to ask for an
  /// unbounded one; clamped at parse rather than trusted.
  final int maxLength;

  static const defaultMaxLength = 64;
  static const maxMaxLength = 512;
}

/// A module asks slim to play a short sound built from these notes, rather
/// than shipping a sample or waveform of its own. Slim renders them with the
/// same bell-like voice `assets/audio/synth.py` renders the app's own
/// notification chimes from (see `scene_synth.dart`, a faithful port of that
/// file's `bell`/`render`), so a module's sound and slim's own always share
/// one timbre instead of the product suddenly sounding like two apps stapled
/// together.
///
/// Never autoplayed: sound triggered by a message is something every
/// viewer's device would make on the strength of whoever posted it, so
/// [ModuleSceneView] only ever plays a `notes` op that comes back as the
/// direct result of *this* viewer's own tap, drag or control press - never
/// on a scene's first paint, and never for a scene update that arrived
/// because another viewer acted on a shared one. A person can also turn
/// module sound off entirely; see `moduleSoundSettingsProvider`.
///
/// The four ceilings below are enforced here, at parse time, not only in the
/// synthesiser: a scene is bounded before anything downstream ever sees an
/// unbounded one. See `docs/decisions/0027-module-scene-sound.md` for the
/// abuse case this whole op is scoped against.
class NotesOp extends SceneOp {
  NotesOp(List<SceneNote> notes) : notes = _bounded(notes);

  final List<SceneNote> notes;

  /// A module scene is a small UI, not a sequencer. More notes than this in
  /// one cue reads as a wall of tone rather than a sound effect, and it also
  /// bounds how much arithmetic one op can ever ask `scene_synth.dart`'s
  /// `render()` to do - the same reasoning `ModuleSceneView`'s own
  /// `_maxQueue` applies to actions.
  static const maxNotes = 32;

  /// A note ringing longer than this is the "hold a tone for an hour" abuse
  /// this ceiling exists to rule out, clamped here rather than only trusted
  /// to a well-behaved module.
  static const maxNoteSeconds = 3.0;

  /// How far into the cue a note may start. Past this a "short sound effect"
  /// has stopped being one; clamped separately from [maxNoteSeconds] so a
  /// module cannot stretch a whole cue's length by starting one note late
  /// rather than by holding it.
  static const maxSceneSeconds = 8.0;

  /// Below this a "note" reads as a sub-bass thump rather than a pitch.
  static const minFrequencyHz = 20.0;

  /// `synth.py`'s highest partial sits at 3.05x the fundamental
  /// (`_PARTIALS`); above this the app renders at 48kHz (`sampleRate` in
  /// `scene_synth.dart`), so that partial would sit past the 24kHz Nyquist
  /// limit and alias back down as noise rather than ring true.
  static const maxFrequencyHz = 7800.0;

  static List<SceneNote> _bounded(List<SceneNote> notes) => [
    for (final note in notes.take(maxNotes))
      SceneNote(
        frequency: note.frequency.clamp(minFrequencyHz, maxFrequencyHz),
        start: note.start.clamp(0.0, maxSceneSeconds),
        seconds: note.seconds.clamp(0.01, maxNoteSeconds),
      ),
  ];
}

/// A whole scene: a logical canvas, the ops to draw on it, the opaque [state]
/// the module wants handed back on the next call, the [controls] to offer, a
/// one-line [status] caption, and whether the scene can still change ([live]).
class ModuleScene {
  const ModuleScene({
    required this.width,
    required this.height,
    required this.ops,
    this.background,
    this.state,
    this.controls = const [],
    this.status,
    this.live = false,
    this.crop,
  });

  /// The part of the canvas worth showing, in scene units, or null for all of
  /// it. See `module_scene_bounds.dart`.
  final Rect? crop;

  ModuleScene withCrop(Rect? crop) => ModuleScene(
    width: width,
    height: height,
    ops: ops,
    background: background,
    state: state,
    controls: controls,
    status: status,
    live: live,
    crop: crop,
  );

  double get viewLeft => crop?.left ?? 0;
  double get viewTop => crop?.top ?? 0;
  double get viewWidth => crop?.width ?? width;
  double get viewHeight => crop?.height ?? height;

  /// The widest ratio between a scene's long and short axis, clamped at parse.
  ///
  /// Chosen from phone width: a 4:1 board on a 390px card is still 98px tall,
  /// enough to see and aim at, where the 1000:1 a module could declare was a
  /// 3px sliver. Like [CellsOp.maxPerAxis] it is a ceiling set by what a
  /// person can use, not by whatever else happens to bound the scene.
  static const maxAspect = 4.0;

  final double width;
  final double height;
  final List<SceneOp> ops;
  final String? background;
  final String? state;
  final List<String> controls;
  final String? status;
  final bool live;
}
