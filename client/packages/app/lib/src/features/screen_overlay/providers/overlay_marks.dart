// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The marks the sharer's overlay window paints, and the repaints that fade
/// them (decision 0096); stamps wait for their picture to reach the runner.
library;

import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:slimm_api/api.dart' as api;
import 'package:slimm_platform/platform.dart';

import 'overlay_draw_queue.dart';
import 'overlay_stamp_images.dart';
import 'screen_annotation_board.dart';
import 'screen_overlay_frame.dart';
import 'stamp_content.dart';
import 'stamp_images.dart';

/// Interval between repaints while a mark is alive.
const overlayFrameInterval = Duration(milliseconds: 33);

bool _systemReducesMotion() =>
    PlatformDispatcher.instance.accessibilityFeatures.disableAnimations;

class OverlayMarks {
  OverlayMarks(
    ScreenOverlay window, {
    required DateTime Function() clock,
    required StampImageCache Function() stamps,
    bool Function()? reduceMotion,
  }) : _clock = clock,
       _stamps = stamps,
       _reduceMotion = reduceMotion ?? _systemReducesMotion,
       _draws = OverlayDrawQueue(window),
       _images = OverlayStampImages(window);

  final DateTime Function() _clock;
  final StampImageCache Function() _stamps;
  final bool Function() _reduceMotion;
  final OverlayDrawQueue _draws;
  final OverlayStampImages _images;
  final _board = ScreenAnnotationBoard();
  Timer? _frames;

  /// Folds in a mark the sharer accepted, and starts the repaints that fade it.
  void add(api.CanvasScreenAnnotation frame) {
    _board.apply(frame, _clock());
    _run();
    if (frame.kind == 'stamp') _ready(frame);
  }

  void _ready(api.CanvasScreenAnnotation frame) {
    final content = StampContent.of(frame);
    final id = frame.annotationId;
    if (content == null || id == null) return;
    final stamps = _stamps();
    unawaited(
      _images.ensure(stamps.keyOf(content), () => stamps.png(content)).then((
        held,
      ) {
        if (held && _board.markReady(id, _clock())) _run();
      }),
    );
  }

  void _run() =>
      _frames ??= Timer.periodic(overlayFrameInterval, (_) => _paint());

  void _paint() {
    final now = _clock();
    final live = _board.liveAt(now);
    final stamps = _stamps();
    _draws.draw(
      overlayShapesFor(
        live,
        now,
        heldImage: (content) {
          final key = stamps.keyOf(content);
          return _images.has(key) ? key : null;
        },
        reduceMotion: _reduceMotion(),
      ),
    );
    if (live.isEmpty) {
      _frames?.cancel();
      _frames = null;
    }
  }

  /// The window was shown or hidden: it is blank and holds no picture.
  void reset() {
    _frames?.cancel();
    _frames = null;
    _board.clear();
    _draws.reset();
    _images.forget();
  }

  void dispose() {
    _frames?.cancel();
    _frames = null;
    _draws.reset();
  }
}
