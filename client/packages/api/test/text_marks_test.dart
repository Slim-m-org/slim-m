// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A stack of combining marks is cut to [kMaxMarksPerBase] per letter
/// wherever a name or message is drawn, and real accented text is untouched.
library;

import 'package:slimm_api/api.dart';
import 'package:test/test.dart';

const _zalgoE = 'e\u{0301}\u{0302}\u{0303}\u{0304}\u{0305}\u{0306}\u{0307}';

int _longestStack(String text) {
  var run = 0;
  var longest = 0;
  for (final c in text.runes) {
    run = c >= 0x0300 && c <= 0x036F ? run + 1 : 0;
    if (run > longest) longest = run;
  }
  return longest;
}

void main() {
  group('capCombiningMarks', () {
    test('cuts a zalgo stack to the cap on every letter', () {
      final capped = capCombiningMarks('$_zalgoE x $_zalgoE');
      expect(_longestStack(capped), kMaxMarksPerBase);
      expect(capped, startsWith('e\u{0301}\u{0302}\u{0303} x'));
    });

    test('leaves real accented, Vietnamese and Hebrew text as it is', () {
      for (final text in [
        'caf\u{00E9} na\u{00EF}ve',
        'Vi\u{1EC7}t Nam, ng\u{01B0}\u{1EDD}i',
        'e\u{0302}\u{0301}',
        '\u{05E9}\u{05C1}\u{05B8}\u{05DC}\u{05D5}\u{05B9}\u{05DD}',
        'keycap 1\u{FE0F}\u{20E3}',
      ]) {
        expect(identical(capCombiningMarks(text), text), isTrue, reason: text);
      }
    });

    test('keeps astral characters whole around a cut stack', () {
      expect(capCombiningMarks('\u{1F600}$_zalgoE\u{1F600}'),
          '\u{1F600}e\u{0301}\u{0302}\u{0303}\u{1F600}');
    });
  });

  test('foldMarks matches a decorated name by its plain letters', () {
    expect(foldMarks('G\u{0337}e\u{0337}n\u{0337}$_zalgoE'), 'gene');
  });

  test('names from the server arrive with their stacks capped', () {
    final profile = UserProfile.fromJson({
      'id': 'u1',
      'username': 'ava',
      'display_name': 'Ava$_zalgoE',
      'status_text': 'busy$_zalgoE',
      'created_at': 0,
    });
    final channel = Channel.fromJson({
      'id': 'c1',
      'name': 'gen$_zalgoE',
      'kind': 'text',
      'created_at': 0,
    });
    expect(_longestStack(profile.displayName), kMaxMarksPerBase);
    expect(_longestStack(profile.statusText!), kMaxMarksPerBase);
    expect(_longestStack(channel.name), kMaxMarksPerBase);
  });
}
