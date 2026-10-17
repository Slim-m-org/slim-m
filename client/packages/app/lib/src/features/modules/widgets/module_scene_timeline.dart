// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The clock behind a scene's `sweep` motion: decision 0043.
///
/// One controller per scene frame, running once for at most
/// [SceneSweep.maxTimelineSeconds] and then stopped. It is never restarted by
/// the module: only a new frame arriving restarts it, and a frame is what the
/// server's rate limit already meters.
library;

import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import 'module_scene.dart';
import 'module_scene_painter.dart';
import 'module_scene_sweep.dart';

/// Paints [scene] with its `sweep` motion playing.
///
/// With no clock the painter shows the end state, which is also what reduced
/// motion and a backgrounded app get, so nobody waits on motion they did not see.
class SceneTimeline extends StatefulWidget {
  const SceneTimeline({
    super.key,
    required this.scene,
    required this.tokens,
    required this.images,
    required this.size,
  });

  final ModuleScene scene;
  final AppTokens tokens;
  final Map<int, ui.Image> images;
  final Size size;

  @override
  State<SceneTimeline> createState() => _SceneTimelineState();
}

class _SceneTimelineState extends State<SceneTimeline>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final AnimationController _controller = AnimationController(vsync: this);
  double _seconds = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context);
    _restart();
  }

  @override
  void didUpdateWidget(SceneTimeline old) {
    super.didUpdateWidget(old);
    if (!identical(old.scene, widget.scene)) _restart();
  }

  // A tick that survives a paused app would replay the whole scene on return.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _controller.stop();
    setState(() {});
  }

  void _restart() {
    _seconds = sceneTimelineSeconds(widget.scene);
    if (_seconds == 0 || _reduceMotion) {
      _controller.stop();
      return;
    }
    _controller.duration = Duration(milliseconds: (_seconds * 1000).round());
    _controller.forward(from: 0);
  }

  bool get _playing => _controller.isAnimating;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => CustomPaint(
    painter: ModuleScenePainter(
      scene: widget.scene,
      tokens: widget.tokens,
      images: widget.images,
      time: _playing ? _controller.drive(Tween(begin: 0, end: _seconds)) : null,
    ),
    size: widget.size,
  );
}
