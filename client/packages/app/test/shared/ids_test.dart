// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A UUIDv7's first 48 bits are its creation time, on every platform.
///
/// Run with `--platform chrome` as well: a bit shift past 32 bits is exact on
/// the VM and wrong when compiled to JavaScript, so the VM run alone passed
/// while the web build minted ids starting `0000`.
library;

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/ids.dart';

void main() {
  test('the first twelve hex digits are the millisecond timestamp', () {
    // 2026-09-30 and a value with every one of the six bytes distinct.
    for (final now in [1790812800000, 0x0102030405FF, 0xFFFFFFFFFFFF]) {
      final id = uuidV7At(now, Random(1)).replaceAll('-', '');
      expect(
        id.substring(0, 12),
        now.toRadixString(16).padLeft(12, '0'),
        reason: 'timestamp $now',
      );
    }
  });

  test('version and variant bits are set', () {
    final id = uuidV7At(1790812800000, Random(1));
    expect(id[14], '7');
    expect('89ab'.contains(id[19]), isTrue);
    expect(id.length, 36);
  });

  test('ids minted a millisecond apart sort in creation order', () {
    final earlier = uuidV7At(1790812800000, Random(2));
    final later = uuidV7At(1790812800001, Random(2));
    expect(earlier.compareTo(later), lessThan(0));
  });
}
