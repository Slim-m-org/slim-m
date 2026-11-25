// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// gal adds the extension itself, so the name handed to it carries none.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/image_export.dart';

void main() {
  test('the extension is dropped once', () {
    expect(galDisplayName('cat.png'), 'cat');
    expect(galDisplayName('my.cat.webp'), 'my.cat');
  });

  test('a name without an extension is kept', () {
    expect(galDisplayName('cat'), 'cat');
    expect(galDisplayName('.hidden'), '.hidden');
  });
}
