// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// `docs/design/wording.md`: a section title never repeats its pane title,
/// and never carries a live count, which the search index cannot match.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_panes_chrome.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_section_header.dart';

import '../../settings_rendered_rows.dart';
import '../../ui_snapshot_support.dart';

void main() {
  for (final pane in {for (final e in spaceSettingsIndex) e.pane}) {
    testWidgets('Space pane $pane names its sections apart from itself', (
      tester,
    ) async {
      final fixture = await pumpSettingsAt(
        tester,
        '/settings/space?pane=$pane',
      );
      await withFixtureTeardown(tester, fixture, () async {
        final headings = [
          for (final e
              in find
                  .byWidgetPredicate((w) => w is SettingsPaneHeading)
                  .evaluate())
            (e.widget as SettingsPaneHeading).label,
        ];
        final titles = [
          for (final e
              in find
                  .byWidgetPredicate((w) => w is SettingsSectionCard)
                  .evaluate())
            (e.widget as SettingsSectionCard).title,
        ];
        for (final heading in headings) {
          expect(titles, isNot(contains(heading)), reason: 'pane $pane');
        }
      });
    });
  }

  test('no Space section title is indexed with a count in it', () {
    final counted = RegExp(r'\(\d');
    expect([
      for (final e in spaceSettingsIndex)
        if (counted.hasMatch(e.label)) e.label,
    ], isEmpty);
  });
}
