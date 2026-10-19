// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/src/system_idle_io.dart';

void main() {
  test('Windows idle time survives the 49.7 day tick wrap', () {
    expect(windowsIdleSince(5000, 2000), const Duration(milliseconds: 3000));
    expect(
      windowsIdleSince(1000, 0xFFFFFFFF - 999),
      const Duration(milliseconds: 2000),
    );
  });

  test('this Linux test host has no system idle source', () {
    expect(createSystemIdle(), isNull);
  });
}
