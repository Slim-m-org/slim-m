// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

/// Whether two byte lists hold the same bytes in the same order.
bool listEquals(List<int> a, List<int> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
