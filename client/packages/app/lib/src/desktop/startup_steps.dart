// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The startup window's checklist: each bootstrap phase as a mono line, a
/// spinner while it runs and a check once the next one starts, with a
/// hairline progress rule along the window's bottom edge. The phases are the
/// real ones `main.dart` reports through `startupStatusProvider`, never a
/// scripted list, so a slow launch shows where it is slow.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// How many phases an ordinary launch reports (session, preferences,
/// connecting); the rule fills against this, or the real count once an
/// update check adds more.
const int kExpectedStartupSteps = 3;

/// The lines the checklist shows at once; older ones scroll off the top.
const int _visibleSteps = 3;

class StartupSteps extends StatelessWidget {
  const StartupSteps({
    super.key,
    required this.steps,
    required this.finished,
    required this.spin,
    required this.tokens,
  });

  /// Every phase reported so far, oldest first; the last is running unless
  /// [finished].
  final List<String> steps;
  final bool finished;

  /// Turns of the running phase's spinner, so it shares the screen's ticker.
  final double spin;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) {
    final shown = steps.length <= _visibleSteps
        ? steps
        : steps.sublist(steps.length - _visibleSteps);
    final offset = steps.length - shown.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final (i, label) in shown.indexed)
          _StepLine(
            key: ValueKey(offset + i),
            label: label,
            running: !finished && offset + i == steps.length - 1,
            spin: spin,
            tokens: tokens,
          ),
      ],
    );
  }
}

/// The share of [StartupSteps] done, for the progress rule.
double startupProgress(int reported, {required bool finished}) {
  if (finished) return 1;
  final done = math.max(0, reported - 1);
  return done / math.max(kExpectedStartupSteps, reported);
}

class _StepLine extends StatelessWidget {
  const _StepLine({
    super.key,
    required this.label,
    required this.running,
    required this.spin,
    required this.tokens,
  });

  final String label;
  final bool running;
  final double spin;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => AppFadeIn(
    offset: 6,
    child: SizedBox(
      height: 22,
      child: Row(
        children: [
          SizedBox.square(
            dimension: 14,
            child: Center(
              child: running
                  ? _Spinner(turns: spin, tokens: tokens)
                  : Icon(AppIcons.check, size: 14, color: tokens.textSecondary),
            ),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppText.caption.copyWith(
                fontFamily: AppFonts.mono,
                letterSpacing: 12 * AppTracking.mono,
                height: 1,
                color: running ? tokens.textPrimary : tokens.textSecondary,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Spinner extends StatelessWidget {
  const _Spinner({required this.turns, required this.tokens});

  final double turns;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: 12,
    child: CustomPaint(
      painter: _SpinnerPainter(
        turns: turns,
        track: tokens.borderSubtle,
        head: tokens.textSecondary,
      ),
    ),
  );
}

class _SpinnerPainter extends CustomPainter {
  const _SpinnerPainter({
    required this.turns,
    required this.track,
    required this.head,
  });

  final double turns;
  final Color track;
  final Color head;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = track;
    canvas.drawArc(rect.deflate(0.75), 0, math.pi * 2, false, ring);
    canvas.drawArc(
      rect.deflate(0.75),
      turns * math.pi * 2 - math.pi / 2,
      math.pi / 2,
      false,
      ring..color = head,
    );
  }

  @override
  bool shouldRepaint(_SpinnerPainter oldDelegate) =>
      oldDelegate.turns != turns ||
      oldDelegate.track != track ||
      oldDelegate.head != head;
}

/// The 2px rule along the window's bottom edge, filling as phases finish.
class StartupProgressRule extends StatelessWidget {
  const StartupProgressRule({
    super.key,
    required this.progress,
    required this.tokens,
  });

  final double progress;
  final AppTokens tokens;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: ColoredBox(
      color: tokens.borderSubtle,
      child: Align(
        alignment: Alignment.centerLeft,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: progress),
          duration: AppMotion.reduced(context, AppMotion.base),
          curve: AppMotion.entrance,
          builder: (context, value, _) => FractionallySizedBox(
            widthFactor: value,
            heightFactor: 1,
            child: ColoredBox(color: tokens.textPrimary),
          ),
        ),
      ),
    ),
  );
}
