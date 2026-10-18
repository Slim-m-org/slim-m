// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Strong verdict counts time, so a slower poll reaches it in the same
/// two seconds.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('two one-second polls are as good as forty at 50 ms', () {
    const second = Duration(seconds: 1);
    final slow = StrongInactivityTracker();
    expect(slow.add(strongActive: false, step: second), isFalse);
    expect(slow.add(strongActive: false, step: second), isTrue);

    final fast = StrongInactivityTracker();
    for (var i = 0; i < kStrongInactivePolls - 1; i++) {
      expect(fast.add(strongActive: false), isFalse);
    }
    expect(fast.add(strongActive: false), isTrue);
  });

  test('one slow active poll clears the verdict', () {
    final tracker = StrongInactivityTracker();
    tracker.add(strongActive: false, step: const Duration(seconds: 2));
    expect(tracker.inactive, isTrue);
    expect(
      tracker.add(strongActive: true, step: const Duration(seconds: 1)),
      isFalse,
    );
  });
}
