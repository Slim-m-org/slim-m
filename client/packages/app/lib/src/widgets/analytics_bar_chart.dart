// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A hand-rolled bar chart for the analytics screen's three small series.
///
/// No charting package: three simple bar charts do not carry the weight of a
/// new dependency (see `docs/dependencies.md`), and this project already
/// prefers a `CustomPainter` for exactly this kind of small, bespoke drawing
/// (the speaking ring, the status dot). This one widget is reused for all
/// three series - messages by day, active hours, and memory samples - rather
/// than growing a chart type per series.
///
/// Deliberately not the only representation of its data: a chart with no
/// accessible equivalent is a cue carried by one channel alone, which this
/// project's own accessibility stance treats as a failure everywhere else
/// (presence shape, the speaking glyph). [semanticsLabel] carries the full
/// series as text for assistive tech, and the caller is expected to print
/// the headline numbers (a total, a peak) as ordinary visible text alongside
/// the chart - see `analytics_charts.dart` for where that happens.
///
/// The bars alone were unreadable until [ticks] and [maxLabel] existed: a
/// reader could see the shape and answer no question with it - not which
/// hour the tall bar was, not what the scale was. Both are drawn as real
/// [Text] rather than painted glyphs, so they take the reader's own text
/// scaling and theme colours instead of a second set this widget would have
/// to keep in step.
library;

import 'package:flutter/material.dart';
import 'package:slimm_design_system/design_system.dart';

/// Clear space either side of a tick label before it counts as colliding.
const double _tickBreathingRoom = 8.0;

/// How wide [label] actually renders, rather than a guess from its length.
///
/// An earlier version estimated seven pixels a character and was wrong in the
/// dangerous direction: the real glyphs are half again as wide, so edge labels
/// ran past the chart and neighbours overprinted at narrow widths. Measuring
/// costs one layout per visible tick, of which there are at most a handful.
double _measure(String label, TextStyle style, TextScaler scaler) {
  final painter = TextPainter(
    text: TextSpan(text: label, style: style),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();
  final width = painter.width;
  painter.dispose();
  return width;
}

class AnalyticsBarChart extends StatelessWidget {
  const AnalyticsBarChart({
    super.key,
    required this.values,
    required this.semanticsLabel,
    this.ticks = const {},
    this.maxLabel,
    this.height = 96,
  });

  final List<double> values;
  final String semanticsLabel;

  /// Sparse labels for the axis, keyed by the index of the bar they sit
  /// under. Sparse on purpose: thirty dated bars cannot each carry a date at
  /// any width, and a reader placing a bar within a bar or two of a landmark
  /// is what the axis is for.
  final Map<int, String> ticks;

  /// The value the tallest bar represents, already formatted by the caller
  /// because only the caller knows whether the series counts messages or
  /// bytes. Drawn against the top gridline, which is the height it describes.
  final String? maxLabel;

  final double height;

  /// The ticks that still fit in [width], nearest-first from the edges.
  ///
  /// Keeps a tick only when it clears the last one kept, so a narrow phone
  /// thins the axis instead of overprinting it. First and last are worth
  /// more than the middle ones - they bound the series - so the sweep runs
  /// in index order and the middle is what gives way.
  Map<int, _Tick> _fittingTicks(
    double width,
    TextStyle style,
    TextScaler scaler,
  ) {
    if (ticks.isEmpty || values.isEmpty || width <= 0) return const {};
    final barWidth = width / values.length;
    final kept = <int, _Tick>{};
    var lastRight = double.negativeInfinity;
    for (final index in ticks.keys.toList()..sort()) {
      final label = ticks[index]!;
      final labelWidth = _measure(label, style, scaler);
      final centre = (index + 0.5) * barWidth;
      final left = centre - labelWidth / 2;
      if (left < lastRight) continue;
      kept[index] = _Tick(label, labelWidth);
      lastRight = centre + labelWidth / 2 + _tickBreathingRoom;
    }
    return kept;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<AppTokens>()!;
    final labelStyle = AppText.micro.copyWith(color: tokens.textSecondary);

    return Semantics(
      label: semanticsLabel,
      child: ExcludeSemantics(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth;
            final fitting = _fittingTicks(
              width,
              labelStyle,
              MediaQuery.textScalerOf(context),
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (maxLabel case final label?)
                  Align(
                    alignment: Alignment.centerRight,
                    child: Text(label, style: labelStyle),
                  ),
                CustomPaint(
                  size: Size(width, height),
                  painter: _BarsPainter(
                    values: values,
                    barColor: tokens.accentFill,
                    baselineColor: tokens.borderSubtle,
                    gridlineColor: tokens.borderSubtle,
                    drawGridline: maxLabel != null,
                  ),
                ),
                if (fitting.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.s4),
                  _TickRow(
                    ticks: fitting,
                    barCount: values.length,
                    width: width,
                    style: labelStyle,
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// One axis label and the width it actually renders at.
class _Tick {
  const _Tick(this.label, this.width);

  final String label;
  final double width;
}

/// The axis labels, each centred under the bar it names.
///
/// A [Stack] rather than a [Row]: a row would space labels evenly and quietly
/// lie about which bar each one belongs to, which is the whole thing this
/// axis exists to fix.
class _TickRow extends StatelessWidget {
  const _TickRow({
    required this.ticks,
    required this.barCount,
    required this.width,
    required this.style,
  });

  final Map<int, _Tick> ticks;
  final int barCount;
  final double width;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    final barWidth = width / barCount;
    return SizedBox(
      width: width,
      height: (style.fontSize ?? 10) * 1.6,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (final entry in ticks.entries)
            Positioned(
              // Centred on its bar, then clamped inside the chart's own width.
              left: ((entry.key + 0.5) * barWidth - entry.value.width / 2)
                  .clamp(0.0, (width - entry.value.width).clamp(0.0, width))
                  .toDouble(),
              child: Text(entry.value.label, style: style, maxLines: 1),
            ),
        ],
      ),
    );
  }
}

class _BarsPainter extends CustomPainter {
  _BarsPainter({
    required this.values,
    required this.barColor,
    required this.baselineColor,
    required this.gridlineColor,
    required this.drawGridline,
  });

  final List<double> values;
  final Color barColor;
  final Color baselineColor;
  final Color gridlineColor;
  final bool drawGridline;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(
      Offset(0, size.height),
      Offset(size.width, size.height),
      Paint()
        ..color = baselineColor
        ..strokeWidth = 1,
    );
    // The height the stated maximum describes, so the number names a real line.
    if (drawGridline) {
      canvas.drawLine(
        const Offset(0, 0.5),
        Offset(size.width, 0.5),
        Paint()
          ..color = gridlineColor.withValues(alpha: 0.5)
          ..strokeWidth = 1,
      );
    }
    if (values.isEmpty || size.width <= 0) return;

    final maxValue = values.fold<double>(0, (m, v) => v > m ? v : m);
    final barWidth = size.width / values.length;
    final gap = barWidth * 0.2;
    final paint = Paint()..color = barColor;
    for (var i = 0; i < values.length; i++) {
      if (maxValue <= 0) break;
      final barHeight = (values[i] / maxValue) * (size.height - 2);
      if (barHeight <= 0) continue;
      canvas.drawRect(
        Rect.fromLTWH(
          i * barWidth + gap / 2,
          size.height - barHeight,
          barWidth - gap,
          barHeight,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _BarsPainter oldDelegate) =>
      oldDelegate.values != values ||
      oldDelegate.barColor != barColor ||
      oldDelegate.drawGridline != drawGridline;
}
