// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Reading a module's opaque output string into a [ModuleScene].
///
/// Split from `module_scene.dart` when gradient fills took that file past its
/// hard line ceiling. The seam is model versus parser, which is the right one:
/// the model is what the painter and the view are written against, and this is
/// the one place that trusts nothing - every value here came from a module, so
/// every read is defensive and every ceiling is applied before anything
/// downstream can hold an unbounded scene.
///
/// `sealed` restricts extending [SceneOp], not constructing one, so the ops can
/// stay in the model file while their parsing lives here.
///
/// The rule the whole file follows: an op that cannot be used is skipped, and a
/// field that cannot be read falls back. Nothing here throws, because a scene
/// that refused to render would cost a reader the whole message rather than one
/// shape.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'module_scene.dart';
import 'module_scene_bounds.dart';
import 'module_scene_path.dart';
import 'module_scene_sweep.dart';
import 'package:slimm_api/api.dart' show AppLog, LogTag;

/// Reads [raw] as a scene, or returns null if it is not one - the fast path
/// for the overwhelmingly common case of ordinary text output. Never throws:
/// malformed JSON, a wrong tag or a bad field all fall back to null (or a
/// skipped op) so a broken scene degrades to plain text rather than an error.
ModuleScene? parseModuleScene(String raw) {
  final trimmed = raw.trimLeft();
  if (!trimmed.startsWith('{')) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(trimmed);
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'A module sent a scene that is not valid JSON; ignoring it',
      error,
      stack,
    );
    return null;
  }
  if (decoded is! Map || decoded[r'$slim'] != 'scene/1') return null;

  final ops = _parseOps(decoded['ops']);

  final (width, height) = _boundedAspect(
    _double(decoded['width'], 100),
    _double(decoded['height'], 100),
  );
  final scene = ModuleScene(
    width: width,
    height: height,
    ops: ops,
    background: _string(decoded['background']),
    state: _string(decoded['state']),
    controls: _stringList(decoded['controls']),
    status: _string(decoded['status']),
    live: decoded['live'] == true,
    isPrivate: decoded['private'] == true,
  );
  return ModuleScene(
    width: scene.width,
    height: scene.height,
    ops: scene.ops,
    background: scene.background,
    state: scene.state,
    controls: scene.controls,
    status: scene.status,
    live: scene.live,
    isPrivate: scene.isPrivate,
    crop: sceneContentBounds(scene),
  );
}

List<SceneOp> _parseOps(Object? opsRaw) {
  final ops = <SceneOp>[];
  if (opsRaw is! List) return ops;
  var images = 0;
  var animated = 0;
  for (final entry in opsRaw) {
    if (entry is! Map) continue;
    final op = _parseOp(entry, allowSweep: animated < SceneSweep.maxPerScene);
    if (op == null) continue;
    if (sweepOf(op) != null) animated++;
    // Counted here: _parseOp sees one op and cannot know how many preceded it.
    if (op is ImageOp && ++images > ImageOp.maxPerScene) continue;
    ops.add(op);
  }
  return ops;
}

SceneOp? _parseOp(Map<Object?, Object?> op, {required bool allowSweep}) {
  final sweep = allowSweep ? SceneSweep.parse(op['sweep']) : null;
  switch (op['op']) {
    case 'cells':
      final data = _string(op['data']);
      if (data == null) return null;
      return CellsOp(
        cols: _axis(op['cols']),
        rows: _axis(op['rows']),
        data: data,
        palette: _stringList(op['palette']),
        gap: _double(op['gap'], 0),
        tap: _string(op['tap']),
        alt: _string(op['alt']),
        tapBatch: op['tap_batch'] == true,
        box: _parseBox(op),
      );
    case 'rect':
      return RectOp(
        x: _double(op['x'], 0),
        y: _double(op['y'], 0),
        w: _double(op['w'], 0),
        h: _double(op['h'], 0),
        fill: _string(op['fill']),
        gradient: _parseGradient(op['grad']),
        stroke: _string(op['stroke']),
        strokeWidth: _double(op['sw'], 1),
        radius: _double(op['r'], 0),
        tap: _string(op['tap']),
        alt: _string(op['alt']),
        sweep: sweep,
      );
    case 'circle':
      return CircleOp(
        cx: _double(op['cx'], 0),
        cy: _double(op['cy'], 0),
        r: _double(op['r'], 0),
        fill: _string(op['fill']),
        gradient: _parseGradient(op['grad']),
        stroke: _string(op['stroke']),
        strokeWidth: _double(op['sw'], 1),
        tap: _string(op['tap']),
        sweep: sweep,
      );
    case 'line':
      return LineOp(
        x1: _double(op['x1'], 0),
        y1: _double(op['y1'], 0),
        x2: _double(op['x2'], 0),
        y2: _double(op['y2'], 0),
        stroke: _string(op['stroke']),
        strokeWidth: _double(op['sw'], 1),
        sweep: sweep,
      );
    case 'path':
      final d = _string(op['d']);
      if (d == null) return null;
      final steps = parseScenePathData(d);
      if (steps.isEmpty) return null;
      return PathOp(
        steps: steps,
        fill: _string(op['fill']),
        stroke: _string(op['stroke']),
        strokeWidth: _double(op['sw'], 1),
        tap: _string(op['tap']),
      );
    case 'text':
      final text = _string(op['s']);
      if (text == null) return null;
      return TextOp(
        x: _double(op['x'], 0),
        y: _double(op['y'], 0),
        text: text,
        fill: _string(op['fill']),
        size: _double(op['size'], 12),
        align: _string(op['align']) ?? 'left',
        sweep: sweep,
      );
    case 'input':
      final submit = _string(op['submit']);
      if (submit == null || submit.isEmpty) return null;
      return InputOp(
        x: _double(op['x'], 0),
        y: _double(op['y'], 0),
        w: _double(op['w'], 0),
        submit: submit,
        value: _string(op['value']) ?? '',
        placeholder: _string(op['placeholder']),
        maxLength: _double(
          op['max'],
          InputOp.defaultMaxLength.toDouble(),
        ).toInt().clamp(1, InputOp.maxMaxLength),
      );
    case 'image':
      return _parseImage(op);
    case 'notes':
      final notes = _parseNotes(op['notes']);
      return notes.isEmpty ? null : NotesOp(notes);
    default:
      return null;
  }
}

/// An image op, or null if its payload is missing, oversized, or not base64.
///
/// The length check comes before the decode so an oversized payload costs a
/// comparison rather than an allocation, which is the whole point of having a
/// ceiling at all.
SceneOp? _parseImage(Map<Object?, Object?> op) {
  final encoded = _string(op['b64']);
  if (encoded == null || encoded.isEmpty) return null;
  if (encoded.length > ImageOp.maxEncodedLength) return null;
  final Uint8List bytes;
  try {
    bytes = base64Decode(encoded);
  } on FormatException catch (error, stack) {
    AppLog.swallowed(
      LogTag.ui,
      'A module sent an image that is not valid base64; skipping it',
      error,
      stack,
    );
    return null;
  }
  if (bytes.isEmpty) return null;
  return ImageOp(
    x: _double(op['x'], 0),
    y: _double(op['y'], 0),
    w: _double(op['w'], 0),
    h: _double(op['h'], 0),
    bytes: bytes,
    key: _digest(bytes),
    tap: _string(op['tap']),
  );
}

/// FNV-1a over the bytes, to key the decode cache.
///
/// Not a cryptographic hash and does not need to be: a collision would draw one
/// of this module's own images in place of another, which is a rendering bug
/// rather than a boundary being crossed. What it has to be is cheap, because it
/// runs on every frame a scene arrives.
int _digest(Uint8List bytes) {
  var hash = 0x811c9dc5;
  for (final byte in bytes) {
    hash = ((hash ^ byte) * 0x01000193) & 0x7fffffff;
  }
  return hash;
}

/// Each entry needs a positive frequency and duration and a non-negative
/// start; anything else is dropped rather than failing the whole op, the same
/// "skip what is bad" treatment a malformed cell or hex colour already gets.
List<SceneNote> _parseNotes(Object? raw) {
  if (raw is! List) return const [];
  final notes = <SceneNote>[];
  for (final entry in raw) {
    if (entry is! Map) continue;
    final frequency = _double(entry['f'], 0);
    final start = _double(entry['t'], -1);
    final seconds = _double(entry['d'], 0);
    if (frequency <= 0 || start < 0 || seconds <= 0) continue;
    notes.add(SceneNote(frequency: frequency, start: start, seconds: seconds));
  }
  return notes;
}

/// Where a grid sits, or null for the whole scene.
///
/// A box needs a positive width and height to describe anything, so one
/// missing either reads as absent rather than dropping the op: the grid then
/// fills the scene, which is both the older behaviour and visibly wrong in a
/// way a silently missing grid would not be. `x` and `y` default to the
/// origin, so a module that only wants to shrink a grid need not restate them.
SceneBox? _parseBox(Map<Object?, Object?> op) {
  final w = _double(op['w'], 0);
  final h = _double(op['h'], 0);
  if (w <= 0 || h <= 0) return null;
  return SceneBox(x: _double(op['x'], 0), y: _double(op['y'], 0), w: w, h: h);
}

/// A gradient needs both stops to mean anything, so one without them is no
/// gradient rather than a half of one; the op then falls back to its `fill`.
SceneGradient? _parseGradient(Object? raw) {
  if (raw is! Map) return null;
  final from = _string(raw['from']);
  final to = _string(raw['to']);
  if (from == null || to == null) return null;
  return SceneGradient(
    from: from,
    to: to,
    direction: _string(raw['dir']) ?? 'v',
  );
}

/// A number from a module, or [fallback].
///
/// Non-finite is treated as absent rather than passed on. JSON can carry it -
/// `1e999` decodes to `double.infinity` - and it reaches two different kinds
/// of harm: `toInt()` on it throws `UnsupportedError`, which escapes
/// [parseModuleScene] entirely because only `FormatException` is caught there,
/// and an infinite width or offset reaches the painter. A module is somebody
/// else's code, so this is the same posture as every ceiling in the contract.
double _double(Object? value, double fallback) =>
    value is num && value.isFinite ? value.toDouble() : fallback;

/// One axis of a `cells` grid, clamped to [CellsOp.maxPerAxis].
///
/// Clamped rather than refused, the way [InputOp.maxLength] is: a grid past
/// the ceiling still draws, just no larger than the contract allows, so a
/// module that asks for too much renders small instead of not at all.
int _axis(Object? value) {
  final raw = _double(value, 0).toInt();
  if (raw < 0) return 0;
  return raw > CellsOp.maxPerAxis ? CellsOp.maxPerAxis : raw;
}

String? _string(Object? value) => value is String ? value : null;

List<String> _stringList(Object? value) => value is List
    ? value.whereType<String>().toList(growable: false)
    : const [];

/// Grows the short axis until the ratio is within [ModuleScene.maxAspect].
///
/// Growing rather than shrinking keeps every op at the coordinates the module
/// wrote it at; the scene draws with empty room instead of squashed.
(double, double) _boundedAspect(double width, double height) {
  if (width <= 0 || height <= 0) return (width, height);
  const limit = ModuleScene.maxAspect;
  if (width > height * limit) return (width, width / limit);
  if (height > width * limit) return (height / limit, height);
  return (width, height);
}
