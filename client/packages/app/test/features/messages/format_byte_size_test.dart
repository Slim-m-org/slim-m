// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `formatByteSize` labels an attachment's size. It had no test, yet it holds
/// two things that break quietly: bytes show as a whole number while every
/// larger unit shows one decimal, and the unit climb stops at GB - a value
/// large enough to reach the next unit must stay GB rather than index off the
/// end of the unit list and throw.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/attachment_format.dart';

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

  test(
    'past a terabyte the unit stays GB rather than running off the list',
    () {
      expect(formatByteSize(1024 * _gb), '1024.0 GB');
    },
  );
}
