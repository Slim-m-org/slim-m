// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The box a docked player's native view floats over. Flutter cannot clip or
/// stack a native view, so this reports where the box landed after each
/// paint and hides the view whenever Flutter draws something over it. With
/// no slot left on screen, or a page over it, the video also pauses: nothing
/// plays where it cannot be seen.
library;

import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../../../widgets/native_view_occlusion.dart';
import '../providers/docked_video_player.dart';

class NativeViewSlot extends StatefulWidget {
  const NativeViewSlot({super.key, required this.player, this.show = true});

  final DockedVideoPlayer player;

  /// False to keep the view hidden regardless, such as while an error shows.
  final bool show;

  @override
  State<NativeViewSlot> createState() => _NativeViewSlotState();
}

class _NativeViewSlotState extends State<NativeViewSlot> {
  /// Every mounted slot per player, so a slot moving between layouts does not
  /// hide the view its replacement just showed.
  static final Map<DockedVideoPlayer, int> _mounted = {};

  Rect? _rect;
  Rect? _sentRect;
  bool? _sentVisible;
  bool _routeCurrent = true;

  @override
  void initState() {
    super.initState();
    _mounted.update(widget.player, (n) => n + 1, ifAbsent: () => 1);
    openFloatingSurfaces.addListener(_sync);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final current = ModalRoute.of(context)?.isCurrent ?? true;
    if (_routeCurrent && !current) unawaited(widget.player.pause());
    _routeCurrent = current;
    _scheduleSync();
  }

  @override
  void didUpdateWidget(NativeViewSlot old) {
    super.didUpdateWidget(old);
    if (old.show != widget.show) _scheduleSync();
  }

  @override
  void dispose() {
    openFloatingSurfaces.removeListener(_sync);
    final player = widget.player;
    final left = (_mounted[player] ?? 1) - 1;
    if (left <= 0) {
      _mounted.remove(player);
    } else {
      _mounted[player] = left;
    }
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (_mounted.containsKey(player)) return;
      unawaited(player.setVisible(false));
      unawaited(player.pause());
    });
    super.dispose();
  }

  void _onPainted(Rect rect) {
    if (rect == _rect) return;
    _rect = rect;
    _scheduleSync();
  }

  void _scheduleSync() =>
      SchedulerBinding.instance.addPostFrameCallback((_) => _sync());

  void _sync() {
    if (!mounted) return;
    final rect = _rect;
    if (rect != null && rect != _sentRect && !rect.isEmpty) {
      _sentRect = rect;
      unawaited(
        widget.player.setBounds((
          x: rect.left,
          y: rect.top,
          width: rect.width,
          height: rect.height,
        )),
      );
    }
    final visible =
        widget.show &&
        _routeCurrent &&
        openFloatingSurfaces.value == 0 &&
        rect != null &&
        !rect.isEmpty;
    if (visible == _sentVisible) return;
    _sentVisible = visible;
    unawaited(widget.player.setVisible(visible));
  }

  @override
  Widget build(BuildContext context) => _PaintReporter(
    onPainted: _onPainted,
    child: const ColoredBox(color: Color(0xFF000000)),
  );
}

class _PaintReporter extends SingleChildRenderObjectWidget {
  const _PaintReporter({required this.onPainted, super.child});

  final ValueChanged<Rect> onPainted;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderPaintReporter(onPainted);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderPaintReporter renderObject,
  ) => renderObject.onPainted = onPainted;
}

class _RenderPaintReporter extends RenderProxyBox {
  _RenderPaintReporter(this.onPainted);

  ValueChanged<Rect> onPainted;

  @override
  void paint(PaintingContext context, Offset offset) {
    super.paint(context, offset);
    onPainted(localToGlobal(Offset.zero) & size);
  }
}
