// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The one id-to-palette-slot hash. Changing it reshuffles every person's
/// avatar tint, role dot and canvas cursor colour at once.
library;

/// A stable index in `[0, size)` for [id]: the sum of its code units modulo
/// [size], or 0 when [size] is not positive.
int stableIndexFor(String id, int size) {
  if (size <= 0) return 0;
  var sum = 0;
  for (final unit in id.codeUnits) {
    sum = (sum + unit) % size;
  }
  return sum;
}
