// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lets a tile hold something in front of a camera until it has decoded a frame.
///
/// `CameraView` sits behind a `Widget` from the session, so the tile cannot
/// reach its renderer; it asks [CameraFrameScope] instead.
library;

import 'package:flutter/widgets.dart';

import 'first_frame_gate.dart';

/// Builds with whether the [CameraFrameReporter] below it has seen a decoded frame.
class CameraFrameScope extends StatefulWidget {
  const CameraFrameScope({super.key, required this.builder});

  final Widget Function(BuildContext context, bool hasFrame) builder;

  @override
  State<CameraFrameScope> createState() => _CameraFrameScopeState();
}

class _CameraFrameScopeState extends State<CameraFrameScope> {
  bool _hasFrame = false;

  void _report(bool hasFrame) {
    if (!mounted || hasFrame == _hasFrame) return;
    setState(() => _hasFrame = hasFrame);
  }

  @override
  Widget build(BuildContext context) => _FrameReports(
        report: _report,
        child:
            Builder(builder: (context) => widget.builder(context, _hasFrame)),
      );
}

class _FrameReports extends InheritedWidget {
  const _FrameReports({required this.report, required super.child});

  final void Function(bool hasFrame) report;

  @override
  bool updateShouldNotify(_FrameReports oldWidget) => false;
}

/// Tells the enclosing [CameraFrameScope], if any, whether [tracker] has a frame.
///
/// A tracker that is null or leaves the tree counts as no frame.
class CameraFrameReporter extends StatefulWidget {
  const CameraFrameReporter({
    super.key,
    required this.tracker,
    required this.child,
  });

  final FirstFrameTracker? tracker;
  final Widget child;

  @override
  State<CameraFrameReporter> createState() => _CameraFrameReporterState();
}

class _CameraFrameReporterState extends State<CameraFrameReporter> {
  void Function(bool hasFrame)? _report;

  @override
  void initState() {
    super.initState();
    widget.tracker?.addListener(_push);
    _pushAfterFrame();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _report = context.getInheritedWidgetOfExactType<_FrameReports>()?.report;
  }

  @override
  void didUpdateWidget(CameraFrameReporter oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tracker == oldWidget.tracker) return;
    oldWidget.tracker?.removeListener(_push);
    widget.tracker?.addListener(_push);
    _pushAfterFrame();
  }

  @override
  void dispose() {
    widget.tracker?.removeListener(_push);
    final report = _report;
    // The tree is locked while it unmounts, so the scope cannot rebuild yet.
    WidgetsBinding.instance.addPostFrameCallback((_) => report?.call(false));
    super.dispose();
  }

  void _push() => _report?.call(widget.tracker?.hasFrame ?? false);

  void _pushAfterFrame() =>
      WidgetsBinding.instance.addPostFrameCallback((_) => _push());

  @override
  Widget build(BuildContext context) => widget.child;
}
