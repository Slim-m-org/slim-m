// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The real document title of a tab with unread conversations.
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_platform/platform.dart';
import 'package:web/web.dart' as web;

void main() {
  test('unread conversations show in the tab title and clear again', () {
    web.document.title = 'slim-m';
    final tab = BrowserAttention();
    tab.setUnread(2);
    expect(web.document.title, '(2) slim-m');
    tab.setUnread(0);
    expect(web.document.title, 'slim-m');
  });
}
