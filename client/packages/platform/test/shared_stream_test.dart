// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  test('many listeners share one upstream, opened and closed with them',
      () async {
    var opened = 0;
    var cancelled = 0;
    late StreamController<int> source;
    final shared = SharedStream<int>(() {
      opened++;
      source = StreamController<int>(onCancel: () => cancelled++);
      return source.stream;
    });
    final a = <int?>[];
    final b = <int?>[];
    final subA = shared.stream.listen(a.add);
    final subB = shared.stream.listen(b.add);
    expect(opened, 1);

    source.add(7);
    await Future<void>.delayed(Duration.zero);
    expect(a, [7]);
    expect(b, [7]);

    final late = <int?>[];
    final subC = shared.stream.listen(late.add);
    await Future<void>.delayed(Duration.zero);
    expect(late, [7], reason: 'a late listener gets the latest value at once');

    await subA.cancel();
    await subB.cancel();
    expect(cancelled, 0);
    await subC.cancel();
    expect(cancelled, 1);

    final again = shared.stream.listen((_) {});
    expect(opened, 2, reason: 'a new listener after idle reopens the source');
    await again.cancel();
  });

  test('five accounts reading one source cost one read loop', () async {
    var reads = 0;
    final shared = SharedStream<int>(
      () => polledStream<int>(
        interval: const Duration(milliseconds: 20),
        read: () async => ++reads,
      ),
    );
    final subs = [for (var i = 0; i < 5; i++) shared.stream.listen((_) {})];
    await Future<void>.delayed(const Duration(milliseconds: 110));
    for (final sub in subs) {
      await sub.cancel();
    }
    expect(reads, lessThan(10), reason: 'five loops would read 25 or more');
  });
}
