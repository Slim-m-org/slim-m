// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The phone's launch splash held over the app while the app builds beneath
/// it, then faded out, so the home is already drawn when it shows.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

class LaunchCover extends StatefulWidget {
  const LaunchCover({
    super.key,
    required this.covered,
    required this.cover,
    required this.child,
  });

  /// Once false it never covers again; the fade runs once and the cover leaves the tree.
  final bool covered;
  final Widget cover;
  final Widget child;

  @override
  State<LaunchCover> createState() => _LaunchCoverState();
}

class _LaunchCoverState extends State<LaunchCover> {
  late bool _mounted = widget.covered;

  void _gone() {
    if (!widget.covered && _mounted) setState(() => _mounted = false);
  }

  @override
  Widget build(BuildContext context) {
    final duration = AppMotion.reduced(context, AppMotion.slow);
    if (_mounted && !widget.covered && duration == Duration.zero) {
      _mounted = false;
    }
    return Stack(
      textDirection: TextDirection.ltr,
      fit: StackFit.expand,
      children: [
        widget.child,
        if (_mounted)
          IgnorePointer(
            ignoring: !widget.covered,
            child: AnimatedOpacity(
              opacity: widget.covered ? 1 : 0,
              duration: duration,
              curve: AppMotion.exit,
              onEnd: _gone,
              child: widget.cover,
            ),
          ),
      ],
    );
  }
}
