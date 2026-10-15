// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [initialsFor] is the one initials rule, made public when the 2026-08-11
/// review found a second implementation in `onboarding_shell.dart` without
/// the symbol-stripping - the same name rendered different initials in the
/// server chip than everywhere else.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('strips symbols before taking the first two characters', () {
    expect(initialsFor("N'ick"), 'NI');
    expect(initialsFor('  slim-m  '), 'SL');
    expect(initialsFor('#general'), 'GE');
  });

  test('letters in any script count, and an accent stays on its letter', () {
    expect(initialsFor('Дмитрий'), 'ДМ');
    expect(initialsFor('王小明'), '王小');
    expect(initialsFor('éloïse'), 'ÉL');
    expect(initialsFor('e\u0301va'), 'E\u0301V');
    expect(initialsFor('\u{1F600} sam'), 'SA');
  });

  test('short and empty names degrade rather than throw', () {
    expect(initialsFor('a'), 'A');
    expect(initialsFor('!!!'), '');
    expect(initialsFor(''), '');
  });
}
