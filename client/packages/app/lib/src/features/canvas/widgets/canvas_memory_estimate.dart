// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A canvas object's resident-memory cost has no clean closed form: the only
/// real numbers available are two measured points from
/// `docs/reports/perf-2026-08.md`'s `canvas_memory_benchmark.dart` run. A real
/// `CanvasDocument`, built on Linux desktop, added roughly 23.8 MB above the
/// bare engine's own footprint at 5,000 objects, and roughly 36.2 MB at
/// 20,000 - the report's own median-of-three-runs figures (148,880 kB and
/// 161,308 kB, against a 125,064 kB baseline).
///
/// That report is explicit that per-object cost is not constant: Dart's
/// generational garbage collector grows heap arenas ahead of what is
/// immediately live, so the first few thousand objects "pay for" slack
/// capacity later ones use for free, and a single run's own incremental
/// figure swung roughly 65% against another run of identical code. So this
/// interpolates (or, past 20,000, extrapolates the last segment's slope)
/// between the two real readings rather than assuming a fixed bytes-per-object
/// rate - the best estimate obtainable from what was actually measured,
/// clearly not a promise.
library;

/// One measured (or defined-zero) point: object count, and MB added over the
/// bare engine's own baseline.
class CanvasMemoryAnchor {
  const CanvasMemoryAnchor(this.objects, this.addedMb);

  final int objects;
  final double addedMb;
}

/// The origin (an empty canvas adds nothing) plus the two real readings.
const canvasMemoryAnchors = [
  CanvasMemoryAnchor(0, 0),
  CanvasMemoryAnchor(5000, 23.8),
  CanvasMemoryAnchor(20000, 36.2),
];

/// Whether [objects] sits past every anchor actually measured, so a caller
/// can flag the estimate below as an extrapolation rather than a reading.
bool canvasMemoryEstimateIsExtrapolated(int objects) =>
    objects > canvasMemoryAnchors.last.objects;

/// The estimated MB one client adds holding a canvas of [objects] objects,
/// on top of the bare engine, by piecewise-linear interpolation between
/// [canvasMemoryAnchors] (or continuing the last segment's slope past the
/// highest one measured).
double estimateCanvasMemoryMb(int objects) {
  for (var i = 0; i < canvasMemoryAnchors.length - 1; i++) {
    final from = canvasMemoryAnchors[i];
    final to = canvasMemoryAnchors[i + 1];
    if (objects <= to.objects) {
      final span = to.objects - from.objects;
      final t = span == 0 ? 0.0 : (objects - from.objects) / span;
      return from.addedMb + t * (to.addedMb - from.addedMb);
    }
  }
  final from = canvasMemoryAnchors[canvasMemoryAnchors.length - 2];
  final to = canvasMemoryAnchors.last;
  final slope = (to.addedMb - from.addedMb) / (to.objects - from.objects);
  return to.addedMb + slope * (objects - to.objects);
}
