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

  /// Where everything was at the last layout, and the scroll offset then.
  ({Rect viewport, Rect section, Rect self, double pixels})? _laidOut;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final position = Scrollable.maybeOf(context, axis: Axis.vertical)?.position;
    if (identical(position, _position)) return;
    _position?.removeListener(_apply);
    _position = position?..addListener(_apply);
  }

  @override
  void dispose() {
    _position?.removeListener(_apply);
    super.dispose();
  }

  void _remeasure() {
    final viewport = _rectOf(
      Scrollable.maybeOf(context, axis: Axis.vertical)?.context,
    );
    final section = _rectOf(widget.section.currentContext);
    final self = _rectOf(context);
    final pixels = _position?.pixels;
    _laidOut =
        viewport == null || section == null || self == null || pixels == null
        ? null
        : (viewport: viewport, section: section, self: self, pixels: pixels);
    _apply();
  }

  /// A list lays its children out a frame after the scroll, so a scroll moves the last layout by its delta instead of reading stale positions.
  void _apply() {
    final at = _laidOut;
    final pixels = _position?.pixels;
    if (at == null || pixels == null) return;
    final moved = Offset(0, at.pixels - pixels);
    final shift = _shiftFor(
      at.viewport,
      at.section.shift(moved),
      at.self.shift(moved),
    );
    if (shift != _shift && mounted) setState(() => _shift = shift);
  }

  double _shiftFor(Rect viewport, Rect section, Rect self) =>
      switch (widget.edge) {
        ViewportEdge.top => _within(
          viewport.top - self.top,
          section.bottom - self.bottom,
        ),
        ViewportEdge.bottom => -_within(
          self.bottom - viewport.bottom,
          self.top - section.top,
        ),
      };

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _remeasure();
    });
    return Transform.translate(offset: Offset(0, _shift), child: widget.child);
  }
}
