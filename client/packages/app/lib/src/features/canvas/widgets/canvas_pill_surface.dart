// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The stadium surface the canvas's small pills share, with the keyboard
/// focus ring the design system draws on its own controls.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

class CanvasPillSurface extends StatefulWidget {
  const CanvasPillSurface({
    super.key,
    required this.tokens,
    required this.onTap,
    required this.child,
    this.color,
    this.borderColor,
  });

  final AppTokens tokens;
  final VoidCallback onTap;
  final Widget child;

  /// The fill; [AppTokens.surfaceRaised] when null.
  final Color? color;

  /// The resting outline; [AppTokens.borderSubtle] when null.
  final Color? borderColor;

  @override
  State<CanvasPillSurface> createState() => _CanvasPillSurfaceState();
}

class _CanvasPillSurfaceState extends State<CanvasPillSurface> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    return Material(
      color: widget.color ?? tokens.surfaceRaised,
      shape: StadiumBorder(
        side: _focused
            ? BorderSide(color: tokens.focusRing, width: 2)
            : BorderSide(color: widget.borderColor ?? tokens.borderSubtle),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onFocusChange: (focused) => setState(() => _focused = focused),
        child: widget.child,
      ),
    );
  }
}
