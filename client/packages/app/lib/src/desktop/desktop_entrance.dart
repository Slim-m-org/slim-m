// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The main window's content easing in once, when the splash hands over, so
/// the window does not appear already fully drawn the instant it is shown.
/// The startup mark, still at its splash size, glides from the middle of
/// the window into the rail header's corner and dissolves there: the
/// "Open" beat of the Startup Window design, which cannot be a real OS
/// window growing into another, so the continuity is carried by the mark.
library;

import 'package:flutter/widgets.dart';
import 'package:slimm_design_system/design_system.dart';

import 'startup_lattice.dart' show kStartupMarkSize;

/// The whole entrance, from the first frame of the main window.
const Duration kDesktopEntranceDuration = Duration(milliseconds: 1100);

/// Where the rail header draws the Space icon: 16 in from the left, centred
/// in the 52px header bar.
const Rect _railCorner = Rect.fromLTWH(16, 16, 20, 20);

bool _playedThisProcess = false;

/// Lets a test play the entrance again, as a fresh process would.
@visibleForTesting
void resetDesktopEntranceForTest() => _playedThisProcess = false;

class DesktopEntrance extends StatefulWidget {
  const DesktopEntrance({super.key, required this.child, this.topInset = 0});

  final Widget child;

  /// Height of anything drawn above the rail header (the frameless title
  /// bar), so the mark lands on the header rather than on the bar.
  final double topInset;

  @override
  State<DesktopEntrance> createState() => _DesktopEntranceState();
}

class _DesktopEntranceState extends State<DesktopEntrance>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: kDesktopEntranceDuration,
  );
  late final Animation<double> _content = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.09, 0.55, curve: AppMotion.entrance),
  );
  late final Animation<double> _glide = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.05, 0.77, curve: Curves.easeInOutCubic),
  );
  late final Animation<double> _markFade = CurvedAnimation(
    parent: _controller,
    curve: const Interval(0.73, 1, curve: AppMotion.entrance),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_controller.isAnimating || _controller.isCompleted) return;
    // A Space switch remounts the shell; only the splash hand-over earns the mark's glide.
    if (_playedThisProcess || AppMotion.isReduced(context)) {
      _controller.value = 1;
    } else {
      _playedThisProcess = true;
      _controller.forward();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.passthrough,
    children: [
      FadeTransition(opacity: _content, child: widget.child),
      Positioned.fill(
        child: IgnorePointer(
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => _controller.isCompleted
                ? const SizedBox.shrink()
                : _GlidingMark(
                    glide: _glide.value,
                    opacity: 1 - _markFade.value,
                    target: _railCorner.translate(0, widget.topInset),
                  ),
          ),
        ),
      ),
    ],
  );
}

class _GlidingMark extends StatelessWidget {
  const _GlidingMark({
    required this.glide,
    required this.opacity,
    required this.target,
  });

  final double glide;
  final double opacity;
  final Rect target;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final start = Rect.fromCenter(
        center: constraints.biggest.center(Offset.zero),
        width: kStartupMarkSize,
        height: kStartupMarkSize,
      );
      final rect = Rect.lerp(start, target, glide)!;
      return Stack(
        children: [
          Positioned.fromRect(
            rect: rect,
            child: Opacity(
              opacity: opacity.clamp(0.0, 1.0),
              child: AppBrandMark(size: rect.width),
            ),
          ),
        ],
      );
    },
  );
}
