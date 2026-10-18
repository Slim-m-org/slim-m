// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// When "Strong noise suppression is not running" is worth acting on, shared
/// by the settings note and the capture fallback so they never disagree.
library;

import 'input_gate.dart' show kInputGateDisplayInterval;

/// How long Strong must read inactive before the verdict.
const Duration kStrongInactiveFor = Duration(seconds: 2);

/// How long it must read active before the verdict clears, so one stray frame
/// does not flicker it.
const Duration kStrongActiveFor = Duration(milliseconds: 500);

/// The same two windows as polls at the display rate.
const int kStrongInactivePolls = 40;
const int kStrongActivePolls = 10;

class StrongInactivityTracker {
  Duration _inactive = Duration.zero;
  Duration _active = Duration.zero;
  bool _inactiveVerdict = false;

  /// Whether Strong has been inactive long enough to report.
  bool get inactive => _inactiveVerdict;

  /// Feeds one poll covering [step] and returns [inactive].
  bool add({
    required bool strongActive,
    Duration step = kInputGateDisplayInterval,
  }) {
    if (strongActive) {
      _inactive = Duration.zero;
      _active += step;
      if (_active >= kStrongActiveFor) _inactiveVerdict = false;
    } else {
      _active = Duration.zero;
      _inactive += step;
      if (_inactive >= kStrongInactiveFor) _inactiveVerdict = true;
    }
    return _inactiveVerdict;
  }

  void reset() {
    _inactive = Duration.zero;
    _active = Duration.zero;
    _inactiveVerdict = false;
  }
}
