// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// [initialsFor] is the one initials rule: the first letter or digit of each
/// of the first two words, symbols stripped, in any script.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

void main() {
  test('one letter per word, for the first two words', () {
    expect(initialsFor('Nick Conn'), 'NC');
    expect(initialsFor('Tester'), 'T');
    expect(initialsFor('testuser123'), 'T');
    expect(initialsFor('Ada King Lovelace'), 'AK');
    expect(initialsFor('Jean-Luc Picard'), 'JP');
  });

  test('a single word splits on its symbols, as a handle does', () {
    expect(initialsFor('nick.conn'), 'NC');
    expect(initialsFor('test_user'), 'TU');
    expect(initialsFor('  slim-m  '), 'SM');
    expect(initialsFor("N'ick"), 'NI');
  });

  test('symbols are stripped before a word counts', () {
    expect(initialsFor('#general'), 'G');
    expect(initialsFor('!!! Ada'), 'A');
    expect(initialsFor('(Ada) [Lovelace]'), 'AL');
  });

  test('short and empty names degrade rather than throw', () {
    expect(initialsFor('a'), 'A');
    expect(initialsFor('!!!'), '');
    expect(initialsFor(''), '');
    expect(initialsFor('   '), '');
  });

  test('#2024 names in any script keep their letters', () {
    expect(initialsFor('Αλέξης'), 'Α');
    expect(initialsFor('Αλέξης νίκ'), 'ΑΝ');
    expect(initialsFor('김민준'), '김');
    expect(initialsFor('\u{10400}\u{10401}x'), '\u{10400}');
    expect(initialsFor('7 Seas'), '7S');
  });
}
