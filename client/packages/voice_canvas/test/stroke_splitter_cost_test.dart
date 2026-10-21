// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// C-013: `splitStroke` re-encodes the whole segment whenever a point lowers
/// the running min, so a stroke drawn up and to the left costs far more at
/// pen-up than the same stroke drawn down and to the right.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_voice_canvas/voice_canvas.dart';

List<Offset> _diagonal(int n, double sign) => <Offset>[
      for (var i = 0; i < n; i++)
        Offset(
          5000 + sign * i * 0.37 + (i % 7) * 0.013,
          5000 + sign * i * 0.41 + (i % 5) * 0.017,
        ),
    ];

int _bestMicros(List<Offset> pts) {
  var best = 1 << 62;
  for (var run = 0; run < 5; run++) {
    final sw = Stopwatch()..start();
    splitStroke(pts);
    sw.stop();
    if (sw.elapsedMicroseconds < best) best = sw.elapsedMicroseconds;
  }
  return best;
}

void main() {
  test('an up-left stroke costs about the same as a down-right one', () {
    final down = _diagonal(1500, 1);
    final up = _diagonal(1500, -1);
    splitStroke(down);
    splitStroke(up);
    final downUs = _bestMicros(down);
    final upUs = _bestMicros(up);
    expect(
      upUs,
      lessThan(downUs * 4 + 2000),
      reason: 'up-left $upUs us vs down-right $downUs us',
    );
  });
}
