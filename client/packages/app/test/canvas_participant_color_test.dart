// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `canvasParticipantColorIndex` picks a stable palette slot for a canvas
/// participant from their user id. It had no test, yet it carries the two
/// properties a color index must hold: it is always in range for the palette
/// it will index (an out-of-range answer is a crash on lookup, and an empty
/// palette must fall back to 0 rather than divide by it), and it is
/// deterministic, so the same person keeps the same color across peers and
/// frames.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_cursor_relay.dart';

void main() {
  test(
    'an empty or invalid palette size falls back to 0, never divides by it',
    () {
      expect(canvasParticipantColorIndex('anyone', 0), 0);
      expect(canvasParticipantColorIndex('anyone', -4), 0);
    },
  );

  test('the index is always in range for the palette', () {
    for (final id in [
      'a',
      'user-1234',
      'Zoë',
      '',
      'a-very-long-identity-string',
    ]) {
      for (final size in [1, 3, 8, 64]) {
        final index = canvasParticipantColorIndex(id, size);
        expect(index, inInclusiveRange(0, size - 1), reason: '$id / $size');
      }
    }
  });

  test('the same id maps to the same slot every time', () {
    expect(
      canvasParticipantColorIndex('user-1234', 8),
      canvasParticipantColorIndex('user-1234', 8),
    );
  });

  test('the slot is the code-unit sum modulo the palette size', () {
    // 'ab' is 97 + 98 = 195; 195 % 10 is 5.
    expect(canvasParticipantColorIndex('ab', 10), 5);
  });
}
