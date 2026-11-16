// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The bars a voice message is drawn as, shared by the composer's recording
/// bar and the message player.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// `3:07`-style length of a voice message.
String formatVoiceDuration(Duration d) {
  final seconds = d.inSeconds;
  final rest = (seconds % 60).toString().padLeft(2, '0');
  return '${seconds ~/ 60}:$rest';
}

/// Loudness bars, the part before [progress] drawn in [playedColor].
class VoiceWaveform extends StatelessWidget {
  const VoiceWaveform({
    super.key,
    required this.values,
    required this.playedColor,
    required this.restColor,
    this.progress = 0,
    this.height = 28,
  });

  /// Each from 0 to 1.
  final List<double> values;
  final Color playedColor;
  final Color restColor;

  /// 0 to 1 of the way through the message.
  final double progress;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: CustomPaint(
      size: Size.infinite,
      painter: _WaveformPainter(
        values: values,
        progress: progress,
        playedColor: playedColor,
        restColor: restColor,
      ),
    ),
  );
}

class _WaveformPainter extends CustomPainter {
  _WaveformPainter({
    required this.values,
    required this.progress,
    required this.playedColor,
    required this.restColor,
  });

  final List<double> values;
  final double progress;
  final Color playedColor;
  final Color restColor;

  static const _barWidth = 2.0;
  static const _minBar = 3.0;

  /// Bars never spread wider than this, so a wide row keeps a dense meter.
  static const _maxSlot = 5.0;

  /// Bars never pack tighter than this, so a narrow row merges values, not bars.
  static const _minSlot = 3.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.isEmpty) return;
    final bars = _fit(values, math.max(1, size.width ~/ _minSlot));
    final slot = math.min(size.width / bars.length, _maxSlot);
    final paint = Paint();
    for (var i = 0; i < bars.length; i++) {
      final barHeight = (bars[i].clamp(0.0, 1.0) * size.height).clamp(
        _minBar,
        size.height,
      );
      final x = i * slot + (slot - _barWidth) / 2;
      paint.color = (i + 0.5) / bars.length <= progress
          ? playedColor
          : restColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, (size.height - barHeight) / 2, _barWidth, barHeight),
          const Radius.circular(_barWidth / 2),
        ),
        paint,
      );
    }
  }

  /// [values] as at most [count] bars, each the loudest value it covers.
  static List<double> _fit(List<double> values, int count) {
    if (values.length <= count) return values;
    return [
      for (var i = 0; i < count; i++)
        values
            .sublist(
              i * values.length ~/ count,
              math.max(
                (i + 1) * values.length ~/ count,
                i * values.length ~/ count + 1,
              ),
            )
            .reduce(math.max),
    ];
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.values != values ||
      old.playedColor != playedColor ||
      old.restColor != restColor;
}
