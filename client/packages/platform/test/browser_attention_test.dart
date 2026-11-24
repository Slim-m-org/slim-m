// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The tab title a background tab shows for its unread conversations.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';

void main() {
  test('the title carries the unread count and drops it at zero', () {
    expect(tabTitleFor('slim-m', 3), '(3) slim-m');
    expect(tabTitleFor('slim-m', 0), 'slim-m');
  });
}
