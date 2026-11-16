// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme editor in the Appearance pane: new and editing Harbour, the
/// picker inline and as a sheet, All colours, failing checks, the menu and
/// the discard question, at a laptop and a phone.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/features/settings/widgets/settings_sub_pages.dart';
import 'package:slimm_app/src/features/settings/widgets/theme_editor_page.dart';
import 'package:slimm_design_system/design_system.dart';

import '../ui_snapshot_support.dart';

const _route = '/settings?pane=appearance&page=new-theme';
const _laptop = 'laptop-1280';
const _phone = 'phone-portrait';

Finder _key(String key) => find.byKey(Key(key));

Future<void> _pause(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

Future<void> _show(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await _pause(tester);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await _show(tester, finder);
  await tester.tap(finder);
  await _pause(tester);
}

/// Dark with a teal accent, its fill, ring and focus following it.
ThemeDocument _harbour() {
  final draft = ThemeDraft(ThemeEditorSeed.fromBase('dark'))
    ..setName('Harbour')
    ..setColour('accent', const Color(0xFF2BB3A3));
  final document = draft.document;
  draft.dispose();
  return document;
}

class _MineWithHarbour extends MyThemesController {
  @override
  List<MyTheme> build() {
    super.build();
    return [MyTheme(id: 'harbour', document: _harbour())];
  }
}

final _mine = [myThemesProvider.overrideWith(_MineWithHarbour.new)];

/// Leaves the clean new theme for Harbour, as its Edit in Mine would.
Future<void> _openHarbour(WidgetTester tester) async {
  final stack = SettingsSubPages.of(
    tester.element(_key('theme-editor-tokens')),
  );
  await stack.pop();
  stack.push(
    themeEditorSubPage(ThemeEditorSeed(_harbour(), mineId: 'harbour')),
  );
  await _pause(tester);
}

/// Opens a main colour's picker and types [hex]; [done] keeps it.
Future<void> _pick(
  WidgetTester tester,
  String token,
  String hex, {
  bool done = true,
}) async {
  await _tap(tester, _key('theme-main-$token'));
  await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), hex);
  await _pause(tester);
  if (done) await _tap(tester, find.byKey(AppColourPicker.confirmKey));
}

/// Primary text the colour of the raised surface and a dim accent.
Future<void> _fail(WidgetTester tester) async {
  await _pick(tester, 'textPrimary', '#1F2226');
  await _pick(tester, 'accent', '#1D2B33');
}

Future<void> _capture(
  WidgetTester tester,
  String viewport,
  String name, {
  String theme = darkAndLight,
  Future<void> Function(WidgetTester tester)? then,
  bool harbour = false,
}) => renderSurface(
  tester,
  _route,
  viewport,
  theme,
  'settings-theme-editor-$name-$viewport-$theme',
  overrides: _mine,
  afterSettle: (tester) async {
    if (harbour) await _openHarbour(tester);
    await then?.call(tester);
  },
);

void main() {
  setUpAll(loadRealFonts);

  for (final viewport in [_laptop, _phone]) {
    testWidgets('a new theme at $viewport', (tester) async {
      await _capture(tester, viewport, 'new');
    });

    testWidgets('editing Harbour at $viewport', (tester) async {
      await _capture(tester, viewport, 'edit', harbour: true);
    });

    testWidgets('failing checks at $viewport', (tester) async {
      await _capture(
        tester,
        viewport,
        'failing',
        theme: 'dark',
        then: (tester) async {
          await _fail(tester);
          await _show(tester, _key('theme-contrast-panel'));
        },
      );
    });

    testWidgets('All colours at $viewport', (tester) async {
      await _capture(
        tester,
        viewport,
        'all-colours',
        then: (tester) async {
          if (viewport == _phone) {
            await _tap(tester, _key('theme-group-Accent'));
            await _show(tester, _key('theme-opacity-accentRing'));
          } else {
            await _show(tester, _key('theme-editor-all-colours'));
          }
        },
      );
    });

    testWidgets('leaving with changes at $viewport', (tester) async {
      await _capture(
        tester,
        viewport,
        'discard',
        theme: 'dark',
        then: (tester) async {
          await tester.enterText(_key('theme-editor-name'), 'Harbour at night');
          await _pause(tester);
          await _tap(tester, find.byTooltip('Back to Themes'));
        },
      );
    });
  }

  testWidgets('the Accent picker inline at $_laptop', (tester) async {
    await _capture(
      tester,
      _laptop,
      'picker',
      then: (tester) async {
        await _tap(tester, _key('theme-main-accent'));
        await _show(tester, _key('theme-main-accent'));
      },
    );
  });

  testWidgets('a failing Accent in the picker at $_laptop', (tester) async {
    await _capture(
      tester,
      _laptop,
      'picker-failing',
      theme: 'dark',
      then: (tester) async {
        await _pick(tester, 'accent', '#1E6F68', done: false);
        await _show(tester, _key('theme-main-accent'));
      },
    );
  });

  testWidgets('the picker sheet at $_phone', (tester) async {
    await _capture(
      tester,
      _phone,
      'picker-sheet',
      then: (tester) => _pick(tester, 'accent', '#2BB3A3', done: false),
    );
  });

  testWidgets('saved at $_phone', (tester) async {
    await _capture(
      tester,
      _phone,
      'saved',
      theme: 'light',
      then: (tester) => _tap(tester, _key('theme-editor-save')),
    );
  });

  testWidgets('the menu anchored at $_laptop', (tester) async {
    await _capture(
      tester,
      _laptop,
      'menu',
      theme: 'dark',
      harbour: true,
      then: (tester) => _tap(tester, _key('theme-editor-menu')),
    );
  });

  testWidgets('the menu as a titled sheet at $_phone', (tester) async {
    await _capture(
      tester,
      _phone,
      'menu',
      theme: 'light',
      harbour: true,
      then: (tester) => _tap(tester, _key('theme-editor-menu')),
    );
  });
}
