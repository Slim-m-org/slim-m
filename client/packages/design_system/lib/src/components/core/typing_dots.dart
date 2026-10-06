// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Three staggered pulsing dots: the universal "someone is typing" cue.
///
/// Mounted only while somebody is actually typing, so nothing is left
/// ticking - [AppSpeakingRing]'s own rule. Under reduce-motion the loop
/// never starts and three static dots remain, which still carries the cue
/// because the label naming who is typing sits beside them: motion is never
/// the only signal, matching the reduce-motion glyph precedent.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../app_motion.dart';
import '../../app_tokens.dart';

class AppTypingDots extends StatefulWidget {
  const AppTypingDots({super.key, this.color, this.dotSize = 5});

  /// Defaults to [AppTokens.textSecondary], the label's own ink.
  final Color? color;

  final double dotSize;

  @override
  State<AppTypingDots> createState() => _AppTypingDotsState();
}

class _AppTypingDotsState extends State<AppTypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _t = AnimationController(
    vsync: this,
    duration: AppMotion.typingWave,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (AppMotion.isReduced(context)) {
      _t.stop();
      _t.value = 0;
    } else if (!_t.isAnimating) {
      _t.repeat();
    }
  }

  @override
  void dispose() {
    _t.dispose();
    super.dispose();
  }

  /// Each dot's pulse trails the one before it by a fifth of the loop, so
  /// the three read as a wave rather than blinking in unison.
  double _opacityFor(int index, double t) {
    if (AppMotion.isReduced(context)) return 1;
    final phase = (t - index * 0.2) * 2 * math.pi;
    return 0.35 + 0.5 * (0.5 + 0.5 * math.sin(phase));
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final ink = widget.color ?? tokens.textSecondary;

    return ExcludeSemantics(
      child: AnimatedBuilder(
        animation: _t,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          spacing: 3,
          children: [
            for (var i = 0; i < 3; i++)
              Opacity(
                opacity: _opacityFor(i, _t.value),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: ink, shape: BoxShape.circle),
                  child: SizedBox.square(dimension: widget.dotSize),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
