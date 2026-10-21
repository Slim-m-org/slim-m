// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Resident memory for 10, 25 and 50 decoded images at the sizes the hydrator produces.
/// The hydrator evicts only off-screen images, so a board with every image in view keeps each at full size.
library;

import 'package:flutter_test/flutter_test.dart';

import 'board_fixture.dart';
import 'perf_support.dart';

void main() {
  final log = PerfLog('image_memory');
  tearDownAll(log.flush);

  for (final (w, h) in [(800, 600), (1600, 1200), (2048, 1536)]) {
    for (final count in [10, 25, 50]) {
      testWidgets('$count images at ${w}x$h', (tester) async {
        final doc = buildBoard(BoardSpec(images: count));
        final before = rssKb();
        await tester
            .runAsync(() => attachBitmaps(doc, count, width: w, height: h));
        final grown = rssKb() - before;
        final decoded = count * w * h * 4 / 1048576;
        log.value('$count images at ${w}x$h: decoded bytes (MiB)', decoded,
            unit: 'MiB');
        log.value(
            '$count images at ${w}x$h: resident growth (MiB)', grown / 1024,
            unit: 'MiB');
        log.value('  drawn at', 320 * 240 / (w * h) * 100,
            unit: '% of the pixels kept');
        doc.dispose();
      });
    }
  }
}
