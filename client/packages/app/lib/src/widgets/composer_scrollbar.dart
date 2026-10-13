// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The scrollbar for the composer's text field, drawn on the bar's own edge.
library;

import 'package:flutter/material.dart';

/// Owns the field's [ScrollController] and draws its thumb against the bar's
/// right edge, past the action icons, rather than at the text column's edge.
///
/// The field's own scrollbar is switched off by the caller; the thumb would
/// otherwise sit between the text and the icons, which reads as the middle of
/// the input.
class ComposerScrollbarFrame extends StatefulWidget {
  const ComposerScrollbarFrame({super.key, required this.builder});

  final Widget Function(BuildContext context, ScrollController controller)
  builder;

  @override
  State<ComposerScrollbarFrame> createState() => _ComposerScrollbarFrameState();
}

class _ComposerScrollbarFrameState extends State<ComposerScrollbarFrame> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      controller: _controller,
      // The text field's scrollable is a descendant, never this widget's own child.
      notificationPredicate: (n) => n.metrics.axis == Axis.vertical,
      child: widget.builder(context, _controller),
    );
  }
}

/// Hides the scrollbar a multiline text field draws for itself.
///
/// The field forces its own scrollbar on through a copy of the ambient
/// behavior, so only a behavior that draws none can switch it off.
class ScrollbarFreeScope extends StatelessWidget {
  const ScrollbarFreeScope({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!active) return child;
    return ScrollConfiguration(
      behavior: const _NoScrollbarBehavior(),
      child: child,
    );
  }
}

class _NoScrollbarBehavior extends MaterialScrollBehavior {
  const _NoScrollbarBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
