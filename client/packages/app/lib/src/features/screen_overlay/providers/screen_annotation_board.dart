// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks viewers have drawn on a shared screen, and how long each stays.
///
/// Ephemeral by design: nothing here is stored, a mark is held a few seconds
/// after its last frame and then fades out. Both the sharer's overlay and a
/// viewer's own annotate layer render from one of these, so what a viewer
/// sees fade is what the sharer saw fade.
library;

import 'package:clock/clock.dart';
import 'package:slimm_api/api.dart' as api;

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
  note;

  static ScreenAnnotationKind? parse(String raw) => switch (raw) {
    'stroke' => stroke,
    'shape' => shape,
    'note' => note,
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
  }) : touchedAt = now;

  final String id;
  final String authorId;
  final ScreenAnnotationKind kind;
  final String? colorKey;
  final List<double> points = [];
  String? text;
  DateTime touchedAt;
  DateTime? finishedAt;

  Duration get _hold =>
      kind == ScreenAnnotationKind.note ? annotationNoteHold : annotationHold;

  /// 1 while being drawn or held, falling to 0 over [annotationFade].
  double alphaAt(DateTime now) {
    final done = finishedAt ?? _staleFinish(now);
    if (done == null) return 1;
    final past = now.difference(done) - _hold;
    if (past <= Duration.zero) return 1;
    if (past >= annotationFade) return 0;
    return 1 - past.inMicroseconds / annotationFade.inMicroseconds;
  }

  DateTime? _staleFinish(DateTime now) =>
      now.difference(touchedAt) > annotationStaleAfter ? touchedAt : null;

  bool expiredAt(DateTime now) => alphaAt(now) <= 0;
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

  void _evictOldest() {
    while (_byId.length > maxLiveAnnotations) {
      _byId.remove(_byId.keys.first);
    }
  }

  /// The marks still visible at [now], oldest first; the faded are dropped.
  List<ScreenAnnotation> liveAt(DateTime now) {
    _byId.removeWhere((_, mark) => mark.expiredAt(now));
    return _byId.values.toList(growable: false);
  }

  void clear() => _byId.clear();
}
