// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
@TestOn('browser')
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/downloads/download_target_web.dart';
import 'package:web/web.dart' as web;

void main() {
  test('a link download loads in a hidden frame, not the app document', () {
    final before = web.window.location.href;

    final frame = downloadInFrame(Uri.parse('http://localhost:9/downloads/x'));

    expect(frame.parentNode, web.document.body);
    expect(frame.src, 'http://localhost:9/downloads/x');
    expect(frame.style.display, 'none');
    expect(web.window.location.href, before);
    frame.remove();
  });
}
