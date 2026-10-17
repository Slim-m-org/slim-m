// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `specForLanguage` resolves a code fence's language tag to the highlighting
/// spec for it, and it was untested. It normalizes case and surrounding space
/// and follows aliases, so `` ```JS `` and `` ```javascript `` light up the
/// same way, while an unknown or absent tag falls back to plain text rather
/// than mis-highlighting.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/messages/widgets/message_code_langs.dart';

void main() {
  test('a null or unknown tag has no spec, so the block stays plain', () {
    expect(specForLanguage(null), isNull);
    expect(specForLanguage('definitely-not-a-language'), isNull);
  });

  test('a known tag resolves, ignoring case and surrounding space', () {
    final dart = specForLanguage('dart');
    expect(dart, isNotNull);
    expect(specForLanguage('DART'), same(dart));
    expect(specForLanguage('  dart  '), same(dart));
  });

  test('an alias resolves to the same spec as its canonical language', () {
    expect(specForLanguage('js'), same(specForLanguage('javascript')));
  });
}
