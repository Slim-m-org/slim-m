// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Space settings Configuration panes in the states the plain pane
/// harness never opens: each role tab, a chosen channel's overwrite grid,
/// and a populated emoji list, at desktop and phone width.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/providers/admin_providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'ui_snapshot_support.dart';

Future<void> _openPane(WidgetTester tester, String pane) async {
  final row = find.widgetWithText(AppListRow, pane);
  await tester.ensureVisible(row);
  await tester.pump();
  await tester.tap(row);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

Future<void> _tab(WidgetTester tester, String label) async {
  await tester.tap(find.textContaining(label).first);
  await tester.pump(const Duration(milliseconds: 350));
}

final _emoji = [
  for (final name in ['party_parrot', 'shipit', 'thonk'])
    api.CustomEmoji(
      id: 'emoji-$name',
      name: name,
      createdAt: 1700000000000,
      uploaderId: 'user-nick',
    ),
];

void main() {
  setUpAll(loadRealFonts);

  for (final theme in const ['dark', 'light']) {
    for (final tab in const ['Members', 'Display']) {
      testWidgets('roles $tab tab at desktop ($theme)', (tester) async {
        await renderSurface(
          tester,
          '/settings/space',
          'desktop',
          theme,
          'space-config-roles-${tab.toLowerCase()}-$theme',
          settleNestedResolve: true,
          afterSettle: (tester) async {
            await _openPane(tester, 'Roles');
            await _tab(tester, tab);
          },
        );
      });
    }

    testWidgets('emoji list at desktop ($theme)', (tester) async {
      await renderSurface(
        tester,
        '/settings/space',
        'desktop',
        theme,
        'space-config-emoji-$theme',
        settleNestedResolve: true,
        overrides: [customEmojiProvider.overrideWith((ref) async => _emoji)],
        afterSettle: (tester) => _openPane(tester, 'Emoji'),
      );
    });

    for (final (route, name) in const [
      ('/settings/roles', 'roles'),
      ('/settings/permissions', 'overwrites'),
      ('/settings/emoji', 'emoji'),
    ]) {
      testWidgets('$name at phone ($theme)', (tester) async {
        await renderSurface(
          tester,
          route,
          'phone-portrait',
          theme,
          'space-config-$name-phone-$theme',
          overrides: [customEmojiProvider.overrideWith((ref) async => _emoji)],
        );
      });
    }
  }
}
