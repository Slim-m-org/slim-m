// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `formatByteSize` is the app's one byte-size label, for an attachment, a
/// backup, a server's disk or a module's store alike: bytes are a whole
/// number, every larger unit carries one decimal, and the climb stops at TB.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/format.dart';

const _kb = 1024;
const _mb = 1024 * 1024;
const _gb = 1024 * 1024 * 1024;

void main() {
  test('bytes are a whole number, with no unit climb below 1024', () {
    expect(formatByteSize(0), '0 B');
    expect(formatByteSize(512), '512 B');
    expect(formatByteSize(1023), '1023 B');
  });

  test('1024 and up climb a unit and carry one decimal', () {
    expect(formatByteSize(_kb), '1.0 KB');
    expect(formatByteSize(_kb + _kb ~/ 2), '1.5 KB');
    expect(formatByteSize(_mb), '1.0 MB');
    expect(formatByteSize(_gb), '1.0 GB');
  });

  test('a terabyte climbs to TB, and past that the unit stays TB', () {
    expect(formatByteSize(1024 * _gb), '1.0 TB');
    expect(formatByteSize(2048 * 1024 * _gb), '2048.0 TB');
  });

  test('a module store reads in the same unit as everything else', () {
    expect(formatByteSize(5 * _mb), '5.0 MB');
  });
}
