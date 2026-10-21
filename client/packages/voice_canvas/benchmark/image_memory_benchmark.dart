// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What decoded images cost to keep: resident memory for 10, 25 and 50 images
/// at the sizes the app's hydrator produces.
///
/// The hydrator decodes to at most 2048 on the long side and evicts only
/// images that are off screen, so a board whose images are all in view keeps
/// every one at full size however small each is drawn.
///
/// Run with `flutter test benchmark/image_memory_benchmark.dart`.
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
