// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Lays the canvas out from the real window while a locked phone is turned for
/// a full screen tile (decision 0086).
///
/// The shell keeps a locked phone's `MediaQuery` portrait (`keepPortraitShell`),
/// so a rotated canvas would still decide its layout from the portrait width.
/// Like the fullscreen video route, it reads the window itself instead.
library;

import 'package:flutter/widgets.dart';

class CanvasRealWindowScope extends StatefulWidget {
  const CanvasRealWindowScope({
    super.key,
    required this.active,
    required this.child,
  });

  final bool active;
  final Widget child;

  @override
  State<CanvasRealWindowScope> createState() => _CanvasRealWindowScopeState();
}

class _CanvasRealWindowScopeState extends State<CanvasRealWindowScope>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // The ambient size is kept portrait, so a rotation never reaches this tree on its own.
  @override
  void didChangeMetrics() {
    if (mounted && widget.active) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) return widget.child;
    final real = MediaQueryData.fromView(View.of(context));
    return MediaQuery(
      data: real.copyWith(
        textScaler: MediaQuery.textScalerOf(context),
        disableAnimations: MediaQuery.disableAnimationsOf(context),
      ),
      child: widget.child,
    );
  }
}
