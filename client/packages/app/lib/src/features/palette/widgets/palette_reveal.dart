// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Keeps the keyboard-highlighted palette row inside its scroll view.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

/// Scrolls [child] into view the moment [active] turns true.
///
/// The palette wraps a section's first row together with its header, so
/// stepping onto that row brings the header into view as well. Scrolls only as
/// far as needed and not at all when the row is already fully visible.
class PaletteReveal extends StatefulWidget {
  const PaletteReveal({super.key, required this.active, required this.child});

  final bool active;
  final Widget child;

  @override
  State<PaletteReveal> createState() => _PaletteRevealState();
}

/// Each only ever scrolls one way, so together they move the least.
const _oneWayPolicies = [
  ScrollPositionAlignmentPolicy.keepVisibleAtEnd,
  ScrollPositionAlignmentPolicy.keepVisibleAtStart,
];

class _PaletteRevealState extends State<PaletteReveal> {
  @override
  void initState() {
    super.initState();
    if (widget.active) _reveal();
  }

  @override
  void didUpdateWidget(PaletteReveal oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active && !oldWidget.active) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final policy in _oneWayPolicies) {
        unawaited(Scrollable.ensureVisible(context, alignmentPolicy: policy));
      }
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
