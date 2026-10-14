// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The main window's content easing in once, when the splash hands over, so
/// the window does not appear already fully drawn the instant it is shown.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

class DesktopEntrance extends StatefulWidget {
  const DesktopEntrance({super.key, required this.child});

  final Widget child;

  @override
  State<DesktopEntrance> createState() => _DesktopEntranceState();
}

class _DesktopEntranceState extends State<DesktopEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: AppMotion.slow,
  );
  late final Animation<double> _curve = CurvedAnimation(
    parent: _controller,
    curve: AppMotion.entrance,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    if (AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FadeTransition(opacity: _curve, child: widget.child);
}
