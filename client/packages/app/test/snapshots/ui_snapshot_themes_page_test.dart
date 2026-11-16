// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The Themes gallery under Appearance at a laptop and a phone: the whole
/// gallery, the Space filter with a picture and a broken theme, a Not saved
/// theme, empty and failed sections, a card's menu and sheet, the confirms,
/// and an import that failed.
library;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/theme_gallery.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';

import '../ui_snapshot_support.dart';
import 'ui_snapshot_themes_fixture.dart';

const _route = '/settings?pane=appearance&page=themes';
const _viewports = ['laptop-1280', 'phone-portrait'];

Finder _key(String key) => find.byKey(Key(key));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 350));
}

/// The picture decodes outside the fake clock.
Future<void> _decode(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 300)),
  );
  await tester.pump();
}

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find
        .descendant(
          of: _key('themes-page-list'),
          matching: find.byWidgetPredicate((w) => w is Scrollable),
        )
        .first,
  );
  await tester.pump();
  await _decode(tester);
}

Future<void> _tapIn(WidgetTester tester, Finder finder) async {
  await tester.tap(finder);
  await _settle(tester);
}

Future<void> _render(
  WidgetTester tester,
  String viewport,
  String theme,
  String name, {
  List<Override>? overrides,
  Future<void> Function(WidgetTester tester)? then,
}) => renderSurface(
  tester,
  _route,
  viewport,
  theme,
  '$name-$viewport-$theme',
  overrides: overrides ?? themesFixture(),
  afterSettle: (tester) async {
    await _decode(tester);
    await then?.call(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in _viewports) {
    testWidgets('the gallery at $viewport', (tester) async {
      await _render(tester, viewport, darkAndLight, 'settings-themes-gallery');
    });

    testWidgets('the Space filter at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        darkAndLight,
        'settings-themes-space',
        overrides: themesFixture(
          applied: pumpkin,
          source: const SpaceThemeSource('pumpkin'),
          filter: ThemeGalleryFilter.space,
        ),
      );
    });

    testWidgets('a Not saved theme at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        darkAndLight,
        'settings-themes-unsaved',
        overrides: themesFixture(
          applied: lilac,
          source: const FileThemeSource(),
          filter: ThemeGalleryFilter.mine,
        ),
      );
    });

    testWidgets('empty sections at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        darkAndLight,
        'settings-themes-empty',
        overrides: themesFixture(mine: false, emptyStore: true),
        then: (tester) => _reveal(tester, _key('theme-store-empty')),
      );
    });

    testWidgets('a store that failed at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        darkAndLight,
        'settings-themes-error',
        overrides: themesFixture(store: false),
        then: (tester) => _reveal(tester, _key('themes-store-error')),
      );
    });
  }

  testWidgets('right-click on a Mine card', (tester) async {
    await _render(
      tester,
      'laptop-1280',
      darkAndLight,
      'settings-themes-menu-mine',
      then: (tester) async {
        await _reveal(tester, _key('theme-mine-harbour'));
        await tester.tapAt(
          tester.getCenter(_key('theme-mine-harbour')),
          buttons: kSecondaryButton,
        );
        await _settle(tester);
      },
    );
  });

  testWidgets('the kebab on the Space default, for an admin', (tester) async {
    await _render(
      tester,
      'laptop-1280',
      'dark',
      'settings-themes-menu-space-admin',
      then: (tester) async {
        await _reveal(tester, _key('theme-menu-pine'));
        await _tapIn(tester, _key('theme-menu-pine'));
      },
    );
  });

  testWidgets('a long-press on the Space default on a phone', (tester) async {
    await _render(
      tester,
      'phone-portrait',
      darkAndLight,
      'settings-themes-sheet-space',
      then: (tester) async {
        await _reveal(tester, _key('theme-store-pine'));
        await tester.longPress(_key('theme-store-pine'));
        await _settle(tester);
      },
    );
  });

  for (final viewport in _viewports) {
    testWidgets('confirming a removal at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        'dark',
        'settings-themes-confirm-remove',
        then: (tester) async {
          await _reveal(tester, _key('theme-menu-pine'));
          await _tapIn(tester, _key('theme-menu-pine'));
          await _tapIn(tester, find.text('Remove'));
        },
      );
    });

    testWidgets('confirming a delete at $viewport', (tester) async {
      await _render(
        tester,
        viewport,
        'light',
        'settings-themes-confirm-delete',
        then: (tester) async {
          await _reveal(tester, _key('theme-mine-harbour-menu'));
          await _tapIn(tester, _key('theme-mine-harbour-menu'));
          await _tapIn(tester, find.text('Delete'));
        },
      );
    });
  }

  testWidgets('an import that failed', (tester) async {
    await _render(
      tester,
      'laptop-1280',
      'dark',
      'settings-themes-import-error',
      overrides: themesFixture(pick: badFile),
      then: (tester) async {
        await _reveal(tester, _key('theme-import'));
        await _tapIn(tester, _key('theme-import'));
        await tester.pump(const Duration(milliseconds: 350));
      },
    );
  });
}
