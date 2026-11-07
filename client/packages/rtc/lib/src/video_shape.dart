// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets a surface that sizes itself to its video, such as the desktop pop-out
/// window, hear the shape of the frames the video below it decodes.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;

/// Receives the width-over-height of the video shown below it, each time it changes.
class VideoShapeScope extends InheritedWidget {
  const VideoShapeScope({
    super.key,
    required this.onShape,
    required super.child,
  });

  final ValueChanged<double> onShape;

  static ValueChanged<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<VideoShapeScope>()?.onShape;

  @override
  bool updateShouldNotify(VideoShapeScope oldWidget) =>
      onShape != oldWidget.onShape;
}

/// Passes [renderer]'s frame shape to the nearest [VideoShapeScope], if any.
class VideoShapeReporter extends StatefulWidget {
  const VideoShapeReporter({
    super.key,
    required this.renderer,
    required this.child,
  });

  final rtc.RTCVideoRenderer? renderer;
  final Widget child;

  @override
  State<VideoShapeReporter> createState() => _VideoShapeReporterState();
}

class _VideoShapeReporterState extends State<VideoShapeReporter> {
  ValueChanged<double>? _onShape;
  double? _reported;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final onShape = VideoShapeScope.maybeOf(context);
    if (onShape == _onShape) return;
    _onShape = onShape;
    _reported = null;
    _listen(null, widget.renderer);
  }

  @override
  void didUpdateWidget(VideoShapeReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.renderer == widget.renderer) return;
    _reported = null;
    _listen(oldWidget.renderer, widget.renderer);
  }

  @override
  void dispose() {
    widget.renderer?.removeListener(_report);
    super.dispose();
  }

  void _listen(rtc.RTCVideoRenderer? from, rtc.RTCVideoRenderer? to) {
    from?.removeListener(_report);
    to?.removeListener(_report);
    if (_onShape == null || to == null) return;
    to.addListener(_report);
    _report();
  }

  void _report() {
    final value = widget.renderer?.value;
    final onShape = _onShape;
    if (value == null || onShape == null) return;
    if (value.width <= 0 || value.height <= 0) return;
    final shape = value.aspectRatio;
    if (shape == _reported) return;
    _reported = shape;
    onShape(shape);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
