// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps a widget inside the enclosing scroll view's visible area while the
/// section it belongs to is on screen: a header slides down with the top
/// edge, a bar slides up with the bottom one.
library;

import 'package:flutter/widgets.dart';

enum ViewportEdge { top, bottom }

class ViewportPin extends StatefulWidget {
  const ViewportPin({
    super.key,
    required this.edge,
    required this.section,
    required this.child,
  });

  final ViewportEdge edge;

  /// The section the child may travel within, so it never floats past it.
  final GlobalKey section;
  final Widget child;

  @override
  State<ViewportPin> createState() => _ViewportPinState();
}

class _ViewportPinState extends State<ViewportPin> {
  ScrollPosition? _position;
  double _shift = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (identical(position, _position)) return;
    _position?.removeListener(_update);
    _position = position?..addListener(_update);
  }

  @override
  void dispose() {
    _position?.removeListener(_update);
    super.dispose();
  }

  void _update() {
    final shift = _measure();
    if (shift != _shift && mounted) setState(() => _shift = shift);
  }

  double _measure() {
    final viewport = _rectOf(
      Scrollable.maybeOf(context, axis: Axis.vertical)?.context,
    );
    final section = _rectOf(widget.section.currentContext);
    final self = _rectOf(context);
    if (viewport == null || section == null || self == null) return 0;
    return switch (widget.edge) {
      ViewportEdge.top => _within(
        viewport.top - self.top,
        section.bottom - self.bottom,
      ),
      ViewportEdge.bottom => -_within(
        self.bottom - viewport.bottom,
        self.top - section.top,
      ),
    };
  }

  /// [distance] held between 0 and [room], and 0 when there is no room at all.
  static double _within(double distance, double room) =>
      room <= 0 || distance <= 0 ? 0 : (distance > room ? room : distance);

  /// The render box before this pin's own shift; a transform moves its child, not itself.
  static Rect? _rectOf(BuildContext? context) {
    final box = context?.findRenderObject();
    if (box is! RenderBox || !box.hasSize || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  @override
  Widget build(BuildContext context) {
    // A layout change moves the section without a scroll, so re-measure once it has settled.
    WidgetsBinding.instance.addPostFrameCallback((_) => _update());
    return Transform.translate(offset: Offset(0, _shift), child: widget.child);
  }
}
