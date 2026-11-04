// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes page under Appearance: with a populated Space section for an
/// admin, with a row menu and the header menu open, and with the store down.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_api/api.dart' as api;
import 'package:slimm_app/src/features/settings/providers/theme_store.dart';
import 'package:slimm_app/src/permissions.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

Map<String, dynamic> _stored(
  String id,
  String name,
  AppTokens tokens,
  String author,
) => {
  'id': id,
  'name': name,
  'author_id': author == 'Nick' ? 'user-nick' : 'user-ren',
  'author_name': author,
  'created_at': 1,
  'has_picture': false,
  'theme': ThemeDocument.of(
    tokens,
    name: name,
    author: author,
    base: 'forest',
    brightness: Brightness.dark,
  ).toJson(),
};

final _populated = [
  meProvider.overrideWith(
    (ref) async => const api.Me(
      id: 'user-nick',
      username: 'nick',
      displayName: 'Nick',
      createdAt: 0,
      permissions: Perm.manageServer,
    ),
  ),
  spaceThemesProvider.overrideWith(
    (ref) async => api.SpaceThemeList.fromJson({
      'default_theme_id': 't1',
      'themes': [
        _stored(
          't1',
          'Pine at dusk over a very long lake',
          AppTokens.forest,
          'Ren',
        ),
        _stored('t2', 'Mine', AppTokens.mocha, 'Nick'),
        _stored('t3', 'Pumpkin', AppTokens.halloween, 'Ren'),
      ],
    }),
  ),
];

Future<void> _tapIn(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in phoneAndDesktop) {
    testWidgets('themes page populated at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes',
        viewport,
        darkAndLight,
        'settings-themes-populated-$viewport-$darkAndLight',
        overrides: _populated,
      );
    });
    testWidgets('themes page row menu at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes',
        viewport,
        'dark',
        'settings-themes-row-menu-$viewport-dark',
        overrides: _populated,
        afterSettle: (tester) async {
          await tester.ensureVisible(find.byKey(const Key('theme-store-t3')));
          await tester.pump(const Duration(milliseconds: 350));
          await tester.drag(
            find.byKey(const Key('theme-store-t3')),
            const Offset(0, -300),
          );
          await tester.pump(const Duration(milliseconds: 350));
          await _tapIn(tester, find.byKey(const Key('theme-menu-t2')));
        },
      );
    });
    testWidgets('themes page header menu at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes',
        viewport,
        'dark',
        'settings-themes-header-menu-$viewport-dark',
        overrides: _populated,
        afterSettle: (tester) =>
            _tapIn(tester, find.byKey(const Key('themes-menu'))),
      );
    });
    testWidgets('themes page store error at $viewport', (tester) async {
      await renderSurface(
        tester,
        '/settings/themes',
        viewport,
        darkAndLight,
        'settings-themes-error-$viewport-$darkAndLight',
      );
    });
  }
}
