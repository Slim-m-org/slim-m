// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks viewers have drawn on a shared screen, and how long each stays.
///
/// Ephemeral by design: nothing here is stored, a mark is held a few seconds
/// after its last frame and then fades out. Both the sharer's overlay and a
/// viewer's own annotate layer render from one of these, so what a viewer
/// sees fade is what the sharer saw fade.
library;

import 'dart:math' as math;

import 'package:clock/clock.dart';
import 'package:slimm_api/api.dart' as api;

import 'screen_stamp_timing.dart';
import 'stamp_content.dart';

/// The current time, read through the clock package so tests can move it.
DateTime annotationNow() => clock.now();

/// How long a finished stroke or shape stays at full strength.
const annotationHold = Duration(seconds: 4);

/// How long a sticky note stays at full strength; longer, since it is read.
const annotationNoteHold = Duration(seconds: 8);

/// The fade-out after the hold.
const annotationFade = Duration(milliseconds: 1500);

/// A mark whose last frame never arrived counts as finished this long after its last frame.
const annotationStaleAfter = Duration(seconds: 2);

/// Marks kept at once; the oldest is dropped past this.
const maxLiveAnnotations = 48;

/// Coordinate values a single stroke may accumulate.
const maxStrokeValues = 2400;

enum ScreenAnnotationKind {
  stroke,
  shape,
  note,

  /// An emoji or a picture (decision 0121); only the server sends one.
  stamp;

  static ScreenAnnotationKind? parse(String raw) => switch (raw) {
    'stroke' => stroke,
    'shape' => shape,
    'note' => note,
    'stamp' => stamp,
    _ => null,
  };
}

/// One mark. [points] are normalised to the shared screen, 0 to 1.
class ScreenAnnotation {
  ScreenAnnotation({
    required this.id,
    required this.authorId,
    required this.kind,
    required this.colorKey,
    required DateTime now,
  }) : touchedAt = now,
       arrivedAt = now;

  final String id;
  final String authorId;
  final ScreenAnnotationKind kind;
  final String? colorKey;
  final List<double> points = [];
  String? text;
  DateTime touchedAt;
  DateTime? finishedAt;
  final DateTime arrivedAt;

  /// A stamp's content, and its longest side as a fraction of the screen's height.
  StampContent? stamp;
  double size = stampDefaultSize;

  /// When a stamp's picture was ready to paint, which is when its clock starts.
  DateTime? readyAt;

  /// When a stamp was made to fade early, by a cap.
  DateTime? _fadeFrom;

  Duration get _hold =>
      kind == ScreenAnnotationKind.note ? annotationNoteHold : annotationHold;

  /// 1 while being drawn or held, falling to 0 over [annotationFade]; a stamp is 0 until it is ready.
  double alphaAt(DateTime now) {
    if (kind == ScreenAnnotationKind.stamp) {
      final fade = _stampFadeStart;
      return fade == null ? 0 : _faded(now.difference(fade));
    }
    final done = finishedAt ?? _staleFinish(now);
    if (done == null) return 1;
    return _faded(now.difference(done) - _hold);
  }

  static double _faded(Duration past) {
    if (past <= Duration.zero) return 1;
    if (past >= annotationFade) return 0;
    return 1 - past.inMicroseconds / annotationFade.inMicroseconds;
  }

  DateTime? get _stampFadeStart {
    final ready = readyAt;
    if (ready == null) return null;
    final natural = ready.add(annotationStampHold);
    final early = _fadeFrom;
    return early != null && early.isBefore(natural) ? early : natural;
  }

  /// The pop-in scale at [now]; 1 for anything but a stamp.
  double scaleAt(DateTime now, {bool reduceMotion = false}) {
    final ready = readyAt;
    if (kind != ScreenAnnotationKind.stamp || ready == null) return 1;
    return stampPopScale(now.difference(ready), reduceMotion: reduceMotion);
  }

  /// A stamp still counting toward the caps: not yet fading.
  bool holdingAt(DateTime now) {
    final fade = _stampFadeStart;
    return kind == ScreenAnnotationKind.stamp &&
        (fade == null ? _fadeFrom == null : now.isBefore(fade));
  }

  DateTime? _staleFinish(DateTime now) =>
      now.difference(touchedAt) > annotationStaleAfter ? touchedAt : null;

  bool expiredAt(DateTime now) {
    if (kind == ScreenAnnotationKind.stamp && readyAt == null) {
      return now.difference(arrivedAt) > annotationStampReadyWithin;
    }
    return alphaAt(now) <= 0;
  }
}

class ScreenAnnotationBoard {
  final Map<String, ScreenAnnotation> _byId = {};

  bool get isEmpty => _byId.isEmpty;
  int get length => _byId.length;

  /// Folds one relayed frame in; consent frames and anything malformed are not marks and are ignored.
  void apply(api.CanvasScreenAnnotation frame, DateTime now) {
    final kind = ScreenAnnotationKind.parse(frame.kind);
    final id = frame.annotationId;
    if (kind == null || id == null) return;
    if (kind == ScreenAnnotationKind.stamp) {
      _applyStamp(id, frame, now);
      return;
    }
    final mark = _byId[id] ??= _fresh(id, kind, frame, now);
    if (mark.kind != kind || mark.authorId != frame.userId) return;
    mark.touchedAt = now;
    switch (kind) {
      case ScreenAnnotationKind.stroke:
        if (mark.points.length + frame.points.length <= maxStrokeValues) {
          mark.points.addAll(frame.points);
        }
      case ScreenAnnotationKind.shape:
      case ScreenAnnotationKind.note:
      case ScreenAnnotationKind.stamp:
        mark.points
          ..clear()
          ..addAll(frame.points);
    }
    if (frame.text != null) mark.text = frame.text;
    if (frame.ended) mark.finishedAt = now;
    _evictOldest();
  }

  ScreenAnnotation _fresh(
    String id,
    ScreenAnnotationKind kind,
    api.CanvasScreenAnnotation frame,
    DateTime now,
  ) => ScreenAnnotation(
    id: id,
    authorId: frame.userId,
    kind: kind,
    colorKey: frame.color,
    now: now,
  );

  /// A stamp arrives once and whole; a repeat of its id changes nothing.
  void _applyStamp(String id, api.CanvasScreenAnnotation frame, DateTime now) {
    final content = StampContent.of(frame);
    final size = frame.size;
    if (_byId.containsKey(id) || content == null || size == null) return;
    if (frame.points.length != 2 || !frame.points.every((v) => v.isFinite)) {
      return;
    }
    _byId[id] = _fresh(id, ScreenAnnotationKind.stamp, frame, now)
      ..stamp = content
      ..size = clampStampSize(size)
      ..finishedAt = now
      ..points.addAll([for (final v in frame.points) v.clamp(0.0, 1.0)]);
    _capStamps(frame.userId, now);
    _evictOldest();
  }

  /// The oldest of one person's stamps past [maxStampsPerAuthor], and of everyone's past [maxStampsPerScreen], start fading at once.
  void _capStamps(String authorId, DateTime now) {
    List<ScreenAnnotation> holding([String? author]) => [
      for (final mark in _byId.values)
        if (mark.holdingAt(now) && (author == null || mark.authorId == author))
          mark,
    ];
    final mine = holding(authorId);
    mine
        .take(math.max(0, mine.length - maxStampsPerAuthor))
        .forEach((mark) => _fadeEarly(mark, now));
    final all = holding();
    all
        .take(math.max(0, all.length - maxStampsPerScreen))
        .forEach((mark) => _fadeEarly(mark, now));
  }

  void _fadeEarly(ScreenAnnotation mark, DateTime now) {
    if (mark.readyAt == null) {
      _byId.remove(mark.id);
    } else {
      mark._fadeFrom = now;
    }
  }

  /// Starts [id]'s clock now that its picture can be painted; false when it is gone or already ready.
  bool markReady(String id, DateTime now) {
    final mark = _byId[id];
    if (mark == null || mark.readyAt != null || mark.expiredAt(now)) {
      return false;
    }
    mark.readyAt = now;
    return true;
  }

  /// Takes [id] off the screen at once, as for a stamp the server refused.
  bool remove(String id) => _byId.remove(id) != null;

  void _evictOldest() {
    while (_byId.length > maxLiveAnnotations) {
      _byId.remove(_byId.keys.first);
    }
  }

  /// Drops the marks that have faded by [now]; true when none are left.
  bool pruneAt(DateTime now) {
    _byId.removeWhere((_, mark) => mark.expiredAt(now));
    return _byId.isEmpty;
  }

  /// The marks still visible at [now], oldest first; the faded are dropped.
  List<ScreenAnnotation> liveAt(DateTime now) {
    pruneAt(now);
    return _byId.values.toList(growable: false);
  }

  void clear() => _byId.clear();
}
