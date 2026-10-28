// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// decodeEdge: real pixels from logical size, and the floor that keeps a
/// window-scaled desktop from starving a small image's decode.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/image_decode.dart';

Future<int> edgeAt(
  WidgetTester tester,
  double dpr,
  double size, {
  double minRatio = 1,
  double oversample = 1,
}) async {
  late int result;
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(devicePixelRatio: dpr),
      child: Builder(
        builder: (context) {
          result = decodeEdge(
            context,
            size,
            minRatio: minRatio,
            oversample: oversample,
          );
          return const SizedBox();
        },
      ),
    ),
  );
  return result;
}

void main() {
  testWidgets('decodes at logical size times the reported ratio', (
    tester,
  ) async {
    expect(await edgeAt(tester, 2, 26), 52);
    expect(await edgeAt(tester, 3, 26), 78);
  });

  testWidgets('the default floor of 1 never changes an honest ratio', (
    tester,
  ) async {
    // A display reporting 2.0 already exceeds the default floor.
    expect(
      await edgeAt(tester, 2, 26),
      await edgeAt(tester, 2, 26, minRatio: 1),
    );
  });

  testWidgets('the floor lifts a decode that an under-reported ratio starves', (
    tester,
  ) async {
    // The Linux fractional-scaling case: reported 1.0, so without the floor a 26px avatar decodes to 26 and goes soft; with it, 52.
    expect(await edgeAt(tester, 1, 26), 26);
    expect(await edgeAt(tester, 1, 26, minRatio: 2), 52);
  });

  testWidgets('a ratio already above the floor is left alone', (tester) async {
    // 3.0 reported beats a floor of 2, so the floor must not pull it down.
    expect(await edgeAt(tester, 3, 26, minRatio: 2), 78);
  });

  testWidgets('oversample multiplies the painted pixels', (tester) async {
    // A 40px avatar at a UI scale of 1.3 paints 52px; 4x headroom decodes 208.
    expect(await edgeAt(tester, 1.3, 40, oversample: 4), 208);
    expect(await edgeAt(tester, 1, 26, minRatio: 2, oversample: 4), 208);
  });
}
