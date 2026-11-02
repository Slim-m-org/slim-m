// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The quiet cue shown when someone talks while their mic is muted.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slimm_rtc/rtc.dart' show InputGateReading;

/// How long speech must run unbroken before the cue is worth showing.
const mutedTalkAfter = Duration(seconds: 1);

const mutedTalkCueText = 'Your mic is muted';

/// Whether the cue is waiting to be shown on the mic's anchor.
final mutedTalkCueProvider = StateProvider<bool>((ref) => false);

/// Counts unbroken speech and fires once per mute.
class MutedTalkTracker {
  Duration _spoken = Duration.zero;
  bool _fired = false;

  /// True on the one reading that completes [mutedTalkAfter] of speech.
  bool add(InputGateReading reading) {
    if (!reading.voice) {
      _spoken = Duration.zero;
      return false;
    }
    _spoken += reading.step;
    if (_fired || _spoken < mutedTalkAfter) return false;
    return _fired = true;
  }

  /// Forgets the mute that just ended.
  void reset() {
    _spoken = Duration.zero;
    _fired = false;
  }
}
