// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/composer/widgets/clipboard_lone_web_address.dart';

void main() {
  test('a browser-copied picture address is a lone web address', () {
    expect(isLoneWebAddress('https://example.com/cat.png'), isTrue);
    expect(isLoneWebAddress('  http://example.com/a?b=c\n'), isTrue);
  });

  test('anything more than one http(s) address is real text', () {
    expect(isLoneWebAddress(''), isFalse);
    expect(isLoneWebAddress('   '), isFalse);
    expect(isLoneWebAddress('see https://example.com/cat.png'), isFalse);
    expect(
      isLoneWebAddress('https://example.com/a\nhttps://example.com/b'),
      isFalse,
    );
    expect(isLoneWebAddress('ftp://example.com/cat.png'), isFalse);
    expect(isLoneWebAddress('https://'), isFalse);
    expect(isLoneWebAddress('Quarterly numbers'), isFalse);
  });
}
