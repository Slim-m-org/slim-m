// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_rtc/rtc.dart';

void main() {
  test('a platform that can switch is told the choice', () async {
    final applied = <bool>[];
    final route =
        SpeakerRoute(supported: true, apply: (on) async => applied.add(on));

    await route.set(false);
    await route.set(true);

    expect(applied, [false, true]);
  });

  test('a platform that cannot switch is never called', () async {
    final applied = <bool>[];
    final route =
        SpeakerRoute(supported: false, apply: (on) async => applied.add(on));

    await route.set(false);

    expect(applied, isEmpty);
  });
}
