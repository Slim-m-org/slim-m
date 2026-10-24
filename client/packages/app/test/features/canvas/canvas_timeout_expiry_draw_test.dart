// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Tests that expired timeout errors unblock drawing and disarm forbidden tools.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';

void main() {
  test('timeout error blocks drawing while active, unblocks after expiry', () {
    const error = "You're timed out and can't draw for another 5 minutes.";
    final future = DateTime.now()
        .add(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    final past = DateTime.now()
        .subtract(const Duration(seconds: 1))
        .millisecondsSinceEpoch;

    expect(canvasErrorBlocksDrawing(error, timedOutUntil: future), isTrue);
    expect(canvasErrorBlocksDrawing(error, timedOutUntil: past), isFalse);
    expect(canvasErrorBlocksDrawing(error), isTrue);
  });
}
