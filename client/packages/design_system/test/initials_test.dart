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

  test('short and empty names degrade rather than throw', () {
    expect(initialsFor('a'), 'A');
    expect(initialsFor('!!!'), '');
    expect(initialsFor(''), '');
  });

  test('#2024 names in any script keep their letters', () {
    expect(initialsFor('\u0391\u03bb\u03ad\u03be\u03b7\u03c2'), '\u0391\u039b');
    expect(initialsFor('\uae40\ubbfc\uc900'), '\uae40\ubbfc');
    expect(initialsFor('\u{10400}\u{10401}x'), '\u{10400}\u{10401}');
    expect(initialsFor("N'ick"), 'NI');
  });
}
