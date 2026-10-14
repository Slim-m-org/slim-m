// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Freezes animated images on their current frame while scrolled out of view.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// Pauses every animated image below it (via [TickerMode]) while this widget
/// lies outside its enclosing scrollable's viewport.
///
/// A lazy list keeps rows alive inside its cache extent, and a short
/// shrink-wrapped thread builds every row, so mounted does not mean seen.
/// Starts running so the first frame always loads, then settles after layout.
class ViewportFreeze extends StatefulWidget {
  const ViewportFreeze({super.key, required this.child});

  final Widget child;

  @override
  State<ViewportFreeze> createState() => _ViewportFreezeState();
}

class _ViewportFreezeState extends State<ViewportFreeze> {
  bool _visible = true;
  bool _checkQueued = false;
  ScrollPosition? _position;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = Scrollable.maybeOf(context)?.position;
    if (next != _position) {
      _position?.removeListener(_scheduleCheck);
      _position = next;
      next?.addListener(_scheduleCheck);
    }
    _scheduleCheck();
  }

  @override
  void didUpdateWidget(ViewportFreeze oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleCheck();
  }

  @override
  void dispose() {
    _position?.removeListener(_scheduleCheck);
    super.dispose();
  }

  /// Scroll listeners fire before layout, so geometry is read after the frame.
  void _scheduleCheck() {
    if (_checkQueued) return;
    _checkQueued = true;
    SchedulerBinding.instance.addPostFrameCallback((_) => _check());
  }

  void _check() {
    _checkQueued = false;
    if (!mounted) return;
    final visible = _inViewport();
    if (visible != _visible) setState(() => _visible = visible);
  }

  bool _inViewport() {
    final box = context.findRenderObject();
    final viewport = Scrollable.maybeOf(context)?.context.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return true;
    if (viewport is! RenderBox || !viewport.hasSize) return true;
    final top = box.localToGlobal(Offset.zero, ancestor: viewport);
    final rect = top & box.size;
    return rect.overlaps(Offset.zero & viewport.size);
  }

  @override
  Widget build(BuildContext context) =>
      TickerMode(enabled: _visible, child: widget.child);
}
