// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [canvasDrawForbiddenMessage]: whether a draw refusal names an active
/// timeout's remaining time, or falls back to the plain permission wording.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/canvas/screens/canvas_forbidden_message.dart';

void main() {
  test('no timeout at all falls back to the plain permission wording', () {
    expect(
      canvasDrawForbiddenMessage(null),
      "You don't have permission to draw here right now.",
    );
  });

  test('an elapsed timeout falls back too, not a claim it is still active', () {
    final past = DateTime.now()
        .subtract(const Duration(minutes: 5))
        .millisecondsSinceEpoch;
    expect(
      canvasDrawForbiddenMessage(past),
      "You don't have permission to draw here right now.",
    );
  });

  test('an active timeout names the freeze and how long it has left', () {
    // A few minutes of slack past the exact hour so this cannot truncate down a bucket.
    final until = DateTime.now()
        .add(const Duration(hours: 3, minutes: 5))
        .millisecondsSinceEpoch;
    final message = canvasDrawForbiddenMessage(until);
    expect(message, contains("You're timed out"));
    expect(message, contains('3h'));
    expect(
      message,
      isNot(contains("don't have permission")),
      reason: 'a real deadline is worth naming instead of the vaguer wording',
    );
  });

  test('a short remaining window still reads in minutes, not zero', () {
    final until = DateTime.now()
        .add(const Duration(minutes: 2, seconds: 30))
        .millisecondsSinceEpoch;
    expect(canvasDrawForbiddenMessage(until), contains('2m'));
  });
}
