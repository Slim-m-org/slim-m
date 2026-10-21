// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Remembers a small copy of each video tile's last real frame, so a tile that is paused, unmounted or still reconnecting can show it blurred instead of a flat colour.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import 'first_frame_gate.dart';

/// The widest a remembered frame is kept; it is only ever shown blurred.
const lastFrameMaxWidth = 160.0;

/// How often a playing tile refreshes its remembered frame.
const lastFrameRefresh = Duration(seconds: 2);

/// The blur radius a remembered frame is shown with.
const lastFrameBlurSigma = 14.0;

/// One image per tile key, oldest dropped past [capacity], so a long call never accumulates frames of people who left.
class LastFrameStore extends ChangeNotifier {
  LastFrameStore({this.capacity = 12});

  static final instance = LastFrameStore();

  final int capacity;
  final LinkedHashMap<String, ui.Image> _frames = LinkedHashMap();

  ui.Image? imageFor(String key) => _frames[key];

  void put(String key, ui.Image image) {
    _frames.remove(key);
    _frames[key] = image;
    while (_frames.length > capacity) {
      _frames.remove(_frames.keys.first);
    }
    notifyListeners();
  }

  @visibleForTesting
  void clear() {
    _frames.clear();
    notifyListeners();
  }

  @visibleForTesting
  int get length => _frames.length;
}

/// Copies a [boundary]'s picture at most [lastFrameMaxWidth] wide, or null when it has nothing painted to copy.
Future<ui.Image?> snapshotLastFrame(RenderRepaintBoundary boundary) async {
  if (!boundary.attached || boundary.debugNeedsPaint) return null;
  final width = boundary.size.width;
  if (width <= 0 || boundary.size.height <= 0) return null;
  try {
    return await boundary.toImage(
      pixelRatio: (lastFrameMaxWidth / width).clamp(0.05, 1.0),
    );
  } on Object {
    // A platform that cannot read a texture back keeps the flat fallback.
    return null;
  }
}

/// Wraps a playing video and refreshes [LastFrameStore]'s copy of [tileKey] while [tracker] says a real frame has painted.
class RememberLastFrame extends StatefulWidget {
  const RememberLastFrame({
    super.key,
    required this.tileKey,
    required this.tracker,
    required this.child,
    this.snapshot = snapshotLastFrame,
    this.refresh = lastFrameRefresh,
  });

  final String tileKey;
  final FirstFrameTracker tracker;
  final Widget child;
  final Future<ui.Image?> Function(RenderRepaintBoundary boundary) snapshot;
  final Duration refresh;

  @override
  State<RememberLastFrame> createState() => _RememberLastFrameState();
}

class _RememberLastFrameState extends State<RememberLastFrame> {
  final _boundary = GlobalKey();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    widget.tracker.addListener(_sync);
    _sync();
  }

  @override
  void didUpdateWidget(covariant RememberLastFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tracker != widget.tracker) {
      oldWidget.tracker.removeListener(_sync);
      widget.tracker.addListener(_sync);
    }
    _sync();
  }

  void _sync() {
    if (!widget.tracker.hasFrame) {
      _timer?.cancel();
      _timer = null;
      return;
    }
    _timer ??= Timer.periodic(widget.refresh, (_) => unawaited(_capture()));
  }

  Future<void> _capture() async {
    final box = _boundary.currentContext?.findRenderObject();
    if (box is! RenderRepaintBoundary) return;
    final image = await widget.snapshot(box);
    if (image == null) return;
    if (!mounted) return;
    LastFrameStore.instance.put(widget.tileKey, image);
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.tracker.removeListener(_sync);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RepaintBoundary(key: _boundary, child: widget.child);
}

/// [tileKey]'s remembered frame, blurred and filling its box; [fallback] when none has been taken.
class BlurredLastFrame extends StatelessWidget {
  const BlurredLastFrame({
    super.key,
    required this.tileKey,
    this.fallback = const SizedBox.expand(),
    this.store,
  });

  final String tileKey;
  final Widget fallback;
  final LastFrameStore? store;

  @override
  Widget build(BuildContext context) {
    final frames = store ?? LastFrameStore.instance;
    return ListenableBuilder(
      listenable: frames,
      builder: (context, _) {
        final image = frames.imageFor(tileKey);
        if (image == null) return fallback;
        return ClipRect(
          child: ImageFiltered(
            imageFilter: ui.ImageFilter.blur(
              sigmaX: lastFrameBlurSigma,
              sigmaY: lastFrameBlurSigma,
              tileMode: TileMode.clamp,
            ),
            child: RawImage(
              image: image,
              fit: BoxFit.cover,
              width: double.infinity,
              height: double.infinity,
            ),
          ),
        );
      },
    );
  }
}
