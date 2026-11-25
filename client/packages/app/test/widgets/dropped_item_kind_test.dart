// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/widgets/dropped_item_kind.dart';

void main() {
  test('a web address is not a file on desktop', () {
    expect(isAddressPath('https://example.com/a.png', web: false), isTrue);
  });

  test('a plain path is a file', () {
    expect(isAddressPath('/home/a/b.png', web: false), isFalse);
  });

  test('a web blob url is a real dropped file on the web', () {
    expect(isAddressPath('blob:https://host/uuid', web: true), isFalse);
  });
}
