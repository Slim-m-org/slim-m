// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The settings search index and the rendered settings agree, both ways: a
/// new row that is not in the index cannot be searched for, and an index
/// entry whose row was renamed or removed would open a pane with nothing on it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/settings_index.dart';

import 'settings_rendered_rows.dart';

void _checkPanes(String scope, String route, List<SettingsEntry> index) {
  final panes = {for (final e in index) e.pane};
  for (final pane in panes) {
    testWidgets('$scope pane $pane matches the search index', (tester) async {
      final rendered = {
        for (final row in await renderedSettingsRows(
          tester,
          '$route?pane=$pane',
        ))
          row.label,
      };
      final indexed = {
        for (final e in index)
          if (e.pane == pane) e.label,
      };
      final required = {
        for (final e in index)
          if (e.pane == pane && !e.conditional) e.label,
      };
      expect(
        rendered.difference(indexed),
        isEmpty,
        reason: 'rows on $pane missing from settings_index.dart',
      );
      expect(
        required.difference(rendered),
        isEmpty,
        reason:
            'index entries on $pane with no such row; mark conditional if gated',
      );
    });
  }
}

void main() {
  _checkPanes('personal', '/settings', personalSettingsIndex);
  _checkPanes('space', '/settings/space', spaceSettingsIndex);
}
