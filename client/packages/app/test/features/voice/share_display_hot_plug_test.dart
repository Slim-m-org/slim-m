// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The share resolution ceiling follows the displays that are plugged in now.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/voice/widgets/share_resolution_support.dart';

void main() {
  testWidgets('a monitor plugged in after the first read raises the ceiling', (
    tester,
  ) async {
    tester.view.display.size = const Size(1920, 1080);
    addTearDown(tester.view.display.reset);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final seen = <List<int>>[];
    container.listen(
      shareDisplayHeightsProvider,
      (_, heights) => seen.add(heights),
      fireImmediately: true,
    );
    expect(seen.single, [1080]);

    tester.view.display.size = const Size(3840, 2160);
    tester.binding.handleMetricsChanged();
    await tester.pump(const Duration(seconds: 1));

    expect(container.read(shareDisplayHeightsProvider), [2160]);
  });
}
