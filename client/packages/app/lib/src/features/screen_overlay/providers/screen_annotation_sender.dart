// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Turns one viewer gesture over a shared screen into relay frames.
///
/// Points arrive already normalised to the shared screen. A stroke goes out as
/// a throttled delta (the server caps a frame at 24 pairs), a shape as its
/// latest ellipse, a note as one frame; each mark's last frame says `ended`.
library;

import 'dart:async';
import 'dart:ui' show Offset;

import 'package:slimm_api/api.dart' as api;

import '../../../ids.dart';

/// Pairs per frame the server accepts.
const maxPairsPerFrame = 24;

/// How often an in-progress mark is flushed.
const annotationFlushInterval = Duration(milliseconds: 66);

class ScreenAnnotationSender {
  ScreenAnnotationSender({
    required this.channelId,
    required this.sharerId,
    required this.selfId,
    required this.colorKey,
    required this.emit,
  });

  final String channelId;
  final String sharerId;
  final String selfId;
  final String colorKey;

  /// Receives every frame: the caller shows it locally and sends it on.
  final void Function(api.CanvasScreenAnnotation frame) emit;

  String? _id;
  final List<double> _pending = [];
  List<double>? _shape;
  Timer? _flush;

  /// Starts a freehand stroke at [at].
  void beginStroke(Offset at) {
    _finish();
    _id = newScreenAnnotationId();
    _pending.addAll([at.dx, at.dy]);
    _arm();
  }

  void extendStroke(Offset at) {
    if (_id == null) return;
    _pending.addAll([at.dx, at.dy]);
  }

  /// Ends the stroke, flushing whatever is left.
  void endStroke() {
    if (_id == null) return;
    _flushStroke(ended: true);
    _id = null;
    _flush?.cancel();
  }

  /// Sets the ellipse spanned by [from] and [to]; the last call before [endShape] is what stays.
  void dragShape(Offset from, Offset to) {
    _id ??= newScreenAnnotationId();
    _shape = [from.dx, from.dy, to.dx, to.dy];
    _arm();
  }

  void endShape() {
    final shape = _shape;
    if (_id == null || shape == null) return;
    _emit('shape', points: shape, ended: true);
    _shape = null;
    _id = null;
    _flush?.cancel();
  }

  /// Places a sticky note with its top-left at [at].
  void note(Offset at, String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _id = newScreenAnnotationId();
    _emit('note', points: [at.dx, at.dy], text: trimmed, ended: true);
    _id = null;
  }

  void dispose() {
    _flush?.cancel();
    _finish();
  }

  void _finish() {
    if (_id == null) return;
    if (_shape != null) {
      endShape();
    } else {
      endStroke();
    }
  }

  void _arm() {
    _flush ??= Timer.periodic(annotationFlushInterval, (_) {
      if (_shape != null) {
        _emit('shape', points: _shape!);
      } else {
        _flushStroke();
      }
    });
  }

  void _flushStroke({bool ended = false}) {
    if (_pending.isEmpty && !ended) return;
    final points = _thin(List.of(_pending));
    _pending.clear();
    _emit('stroke', points: points, ended: ended);
  }

  void _emit(
    String kind, {
    required List<double> points,
    String? text,
    bool ended = false,
  }) {
    final id = _id;
    if (id == null) return;
    emit(
      api.CanvasScreenAnnotation(
        channelId: channelId,
        userId: selfId,
        targetUserId: sharerId,
        kind: kind,
        annotationId: id,
        points: points,
        color: colorKey,
        text: text,
        ended: ended,
        allowed: false,
      ),
    );
  }

  /// At most [maxPairsPerFrame] pairs, evenly spaced and keeping the last, so a long drag between flushes still reaches where the pen is.
  static List<double> _thin(List<double> flat) {
    final pairs = flat.length ~/ 2;
    if (pairs <= maxPairsPerFrame) return flat;
    final out = <double>[];
    for (var i = 0; i < maxPairsPerFrame; i++) {
      final src = (i * (pairs - 1) / (maxPairsPerFrame - 1)).round();
      out
        ..add(flat[src * 2])
        ..add(flat[src * 2 + 1]);
    }
    return out;
  }
}
