// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When "Strong noise suppression is not running" is worth acting on, shared
/// by the settings note and the capture fallback so they never disagree.
library;

/// About 2 s of consecutive inactive polls at the gate's 50 ms interval.
const int kStrongInactivePolls = 40;

/// Active polls in a row before the verdict clears, so one stray frame does
/// not flicker it.
const int kStrongActivePolls = 10;

class StrongInactivityTracker {
  int _inactive = 0;
  int _active = 0;
  bool _inactiveVerdict = false;

  /// Whether Strong has been inactive long enough to report.
  bool get inactive => _inactiveVerdict;

  /// Feeds one poll and returns [inactive].
  bool add({required bool strongActive}) {
    if (strongActive) {
      _inactive = 0;
      if (++_active >= kStrongActivePolls) _inactiveVerdict = false;
    } else {
      _active = 0;
      if (++_inactive >= kStrongInactivePolls) _inactiveVerdict = true;
    }
    return _inactiveVerdict;
  }

  void reset() {
    _inactive = 0;
    _active = 0;
    _inactiveVerdict = false;
  }
}
