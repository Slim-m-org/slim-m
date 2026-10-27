// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The playout limiter behind the web volume, as a pure transfer curve.
///
/// A compressor node adds look-ahead delay and its own make-up gain, so the
/// boost is limited with a waveshaper instead: identity up to [softLimitKnee],
/// then a smooth tanh shoulder that never reaches full scale.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Sample level below which the limiter changes nothing.
const double softLimitKnee = 0.8;

/// The limiter's output for one sample [x]; always inside (-1, 1) past the knee.
double softLimit(double x) {
  final a = x.abs();
  if (a <= softLimitKnee) return x;
  const room = 1.0 - softLimitKnee;
  final y = softLimitKnee + room * _tanh((a - softLimitKnee) / room);
  return x < 0 ? -y : y;
}

/// Whether a playout at [gain] needs the limiter: a signal at or under full
/// scale cannot clip until it is boosted, so a trim must pass untouched.
bool limiterNeeded(double gain) => gain > 1.0;

/// A [points]-long lookup table for a waveshaper whose input spans
/// `[-range, range]` in sample units, so a boosted signal needs no pre-scaling
/// beyond dividing the gain by [range].
Float32List softLimitCurve({required int points, required double range}) {
  final curve = Float32List(points);
  for (var i = 0; i < points; i++) {
    final x = (i / (points - 1) * 2 - 1) * range;
    curve[i] = softLimit(x);
  }
  return curve;
}

double _tanh(double x) {
  final e = math.exp(2 * x);
  return (e - 1) / (e + 1);
}
