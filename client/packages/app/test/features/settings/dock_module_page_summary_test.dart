// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// A module page answers who can use it on the folded row, and shows the
/// display switches only for a module that has badges or profile sections.
library;

import 'package:flutter_test/flutter_test.dart';

import '../../support/dock_module_page_fixtures.dart';

const _badges = 'Show its badges in the member list';
const _sections = 'Show its sections on profiles';

void main() {
  testWidgets('a module the everyone role holds reads Everyone', (
    tester,
  ) async {
    await pumpDockModulePage(tester, 'minesweeper');
    expect(find.text('Everyone'), findsOneWidget);
  });

  testWidgets('a module one role holds names that role', (tester) async {
    await pumpDockModulePage(tester, 'xp');
    expect(find.text('Moderators'), findsOneWidget);
  });

  testWidgets('a module with badges and sections shows both switches', (
    tester,
  ) async {
    await pumpDockModulePage(tester, 'xp');
    expect(find.text('Display'), findsOneWidget);
    expect(find.text(_badges), findsOneWidget);
    expect(find.text(_sections), findsOneWidget);
  });

  testWidgets('a module with neither shows no display switch', (tester) async {
    await pumpDockModulePage(tester, 'minesweeper');
    expect(find.text('Display'), findsNothing);
    expect(find.text(_badges), findsNothing);
  });

  testWidgets('a module that posts and reaches the network keeps every '
      'approval switch, the private network one included', (tester) async {
    await pumpDockModulePage(tester, 'watch');
    for (final label in [
      'Remember data',
      'Post messages',
      'Reach the internet',
      'Private network',
      'Run on its own',
    ]) {
      expect(find.bySemanticsLabel('$label for Watch party'), findsOneWidget);
    }
  });
}
