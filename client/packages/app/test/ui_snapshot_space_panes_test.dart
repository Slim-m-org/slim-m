// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Every Space settings pane at two-pane width, opened by its nav row, so the
/// pane heading is looked at on each rather than only on the first pane.
library;

import 'package:flutter/widgets.dart' show Scrollable;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';
import 'package:slimm_app/src/action_labels.dart';

const _panes = <String>[
  'Reports',
  'Removed members',
  'Invites',
  'Account recovery',
  'Roles',
  'Channel permissions',
  'Emoji',
  ActionLabels.spaceVoice,
  ActionLabels.retentionAndLimits,
  'Analytics',
  'Storage',
  'Server metrics',
  'Modules',
  'Bots',
  'Webhooks',
];

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final pane in _panes) {
      testWidgets('space settings pane $pane at desktop ($theme)', (
        tester,
      ) async {
        await renderSurface(
          tester,
          '/settings/space',
          'desktop',
          theme,
          'space-pane-${pane.toLowerCase().replaceAll(' ', '-')}-$theme',
          settleNestedResolve: true,
          afterSettle: (tester) async {
            final row = find.widgetWithText(AppListRow, pane);
            // The nav is a lazy list, so a pane near the end is built only once scrolled to.
            await tester.scrollUntilVisible(
              row,
              120,
              scrollable: find
                  .ancestor(
                    of: find.widgetWithText(AppListRow, 'Reports'),
                    matching: find.byType(Scrollable),
                  )
                  .first,
            );
            await tester.pump();
            await tester.tap(row);
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 350));
          },
        );
      });
    }
  }
}
