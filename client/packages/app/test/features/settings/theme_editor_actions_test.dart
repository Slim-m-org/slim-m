// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// What the theme editor does with a theme: save, save and apply, publish,
/// export, delete, and asking before unsaved changes are left.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:slimm_app/src/features/settings/providers/my_themes.dart';
import 'package:slimm_app/src/features/settings/providers/stored_theme.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/features/settings/providers/theme_source.dart';
import 'package:slimm_app/src/providers/providers.dart';
import 'package:slimm_design_system/design_system.dart';

import 'theme_editor_harness.dart';

/// Preferences whose writes wait for [gate], as a disk does.
class _SlowStore extends InMemorySharedPreferencesStore {
  _SlowStore() : super.empty();

  final gate = Completer<void>();

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await gate.future;
    return super.setValue(valueType, key, value);
  }
}

/// Preferences that refuse every write, as a full or locked disk does.
class _FailingStore extends InMemorySharedPreferencesStore {
  _FailingStore() : super.empty();

  @override
  Future<bool> setValue(String valueType, String key, Object value) =>
      Future.error(StateError('disk full'));
}

Future<void> _rename(WidgetTester tester, String name) async {
  await tester.enterText(byKey('theme-editor-name'), name);
  await settle(tester);
}

/// The editor is gone and Themes is on top again.
void _expectThemes() {
  expect(byKey('theme-editor-preview'), findsNothing);
  expect(find.byTooltip('Back to Appearance'), findsOneWidget);
}

void _expectAsked(String way) {
  expect(byKey('theme-editor-confirm'), findsOneWidget, reason: way);
  expect(find.text('Discard your changes?'), findsOneWidget, reason: way);
}

Future<void> _keepEditing(WidgetTester tester, String way) async {
  await tapIn(tester, find.text('Keep editing'));
  expect(byKey('theme-editor-confirm'), findsNothing, reason: way);
  expect(byKey('theme-editor-preview'), findsOneWidget, reason: way);
}

void main() {
  testWidgets('Save keeps the theme in Mine and says so; saving again '
      'updates the same entry', (tester) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);
    final preview = tester.getRect(byKey('theme-editor-preview'));

    await _rename(tester, 'Dusk');
    await tapIn(tester, byKey('theme-editor-save'));
    expect(rig.toasts, ['Saved to Mine.']);
    expect(tester.getRect(byKey('theme-editor-preview')), preview);
    expect(find.text('Edit theme'), findsOneWidget);
    await _rename(tester, 'Dusk two');
    await tapIn(tester, byKey('theme-editor-save'));

    final mine = rig.container.read(myThemesProvider);
    expect(mine.map((t) => t.document.name), ['Dusk two']);
    expect(parseThemeJson(mine.single.document.toJson()).problems, isEmpty);
  });

  for (final button in ['theme-editor-save', 'theme-editor-apply']) {
    testWidgets('$button is off while it writes, so a second tap adds no '
        'second theme', (tester) async {
      final rig = EditorRig();
      await rig.open(tester);
      await _rename(tester, 'Once');
      final store = _SlowStore();
      SharedPreferencesStorePlatform.instance = store;

      await tester.tap(byKey(button));
      await tester.pump();
      await tester.tap(byKey(button), warnIfMissed: false);
      await tester.pump();
      expect(saveEnabled(tester), isFalse);
      store.gate.complete();
      await settle(tester);

      final mine = rig.container.read(myThemesProvider);
      expect(mine.map((t) => t.document.name), ['Once']);
      expect(saveEnabled(tester), isTrue);
    });
  }

  testWidgets('a full device is said inline, not saved', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);
    final preview = tester.getRect(byKey('theme-editor-preview'));
    final mine = rig.container.read(myThemesProvider.notifier);
    final filler = ThemeEditorSeed.fromBase('dark').document;
    for (var i = 0; i < myThemesMax; i++) {
      await mine.save(filler);
    }

    await tapIn(tester, byKey('theme-editor-save'));
    expect(
      tester.getRect(byKey('theme-editor-error')).top,
      greaterThan(preview.bottom),
    );
    expect(tester.getRect(byKey('theme-editor-preview')), preview);
    expect(
      find.text('This device holds 50 themes. Delete one first.'),
      findsOneWidget,
    );
  });

  testWidgets('Save and apply saves to Mine and applies it from there', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);

    await _rename(tester, 'Applied');
    await tapIn(tester, byKey('theme-editor-apply'));

    final id = rig.container.read(myThemesProvider).single.id;
    expect(rig.container.read(themeControllerProvider), AppThemeChoice.custom);
    expect(rig.container.read(customThemeProvider)!.name, 'Applied');
    expect(rig.container.read(customThemeSourceProvider)?.key, 'mine:$id');
  });

  testWidgets('saving the theme in use updates the applied copy', (
    tester,
  ) async {
    final rig = EditorRig();
    final doc = ThemeEditorSeed.fromBase(
      'dark',
    ).document.copyWith(name: 'In use');
    await rig.open(tester, seed: ThemeEditorSeed(doc, mineId: 'm1'));
    await rig.container.read(customThemeProvider.notifier).set(doc);

    await _rename(tester, 'In use, renamed');
    await tapIn(tester, byKey('theme-editor-save'));

    expect(rig.container.read(customThemeProvider)!.name, 'In use, renamed');
    expect(
      rig.container.read(customThemeSourceProvider),
      isA<MineThemeSource>(),
    );
  });

  testWidgets('saving the theme in use updates it when the applied copy '
      'carries picture settings that Mine drops', (tester) async {
    final rig = EditorRig();
    final mine = ThemeEditorSeed.fromBase(
      'dark',
    ).document.copyWith(name: 'In use');
    final applied = ThemeDocument(
      name: mine.name,
      author: mine.author,
      base: mine.base,
      brightness: mine.brightness,
      colours: mine.colours,
      picture: const ThemePicture(dim: 0.4, vignette: true, blur: 0.2),
    );
    await rig.open(tester, seed: ThemeEditorSeed(mine, mineId: 'm1'));
    await rig.container.read(customThemeProvider.notifier).set(applied);

    await _rename(tester, 'In use, renamed');
    await tapIn(tester, byKey('theme-editor-save'));

    expect(rig.container.read(customThemeProvider)!.name, 'In use, renamed');
  });

  testWidgets('publishing posts the theme file under the member name', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    rig.container.listen(meProvider, (_, _) {});
    await rig.container.read(meProvider.future);

    await pickFromMenu(tester, 'Publish to Space');

    expect(rig.calls, contains('POST /space/themes'));
    final body = rig.published! as Map<String, dynamic>;
    expect(body['format'], 'slimm-theme');
    expect(body['author'], 'Self');
    expect(rig.toasts, ['Published to the Space.']);
  });

  testWidgets('a full author quota is shown, not swallowed', (tester) async {
    final rig = EditorRig(
      publishStatus: 409,
      publishMessage:
          'you have published 5 themes already - remove one to publish another',
    );
    await rig.open(tester);

    await pickFromMenu(tester, 'Publish to Space');

    expect(byKey('theme-editor-error'), findsOneWidget);
    expect(find.textContaining('published 5 themes already'), findsOneWidget);
  });

  testWidgets('a full Space is shown, not swallowed', (tester) async {
    final rig = EditorRig(
      publishStatus: 409,
      publishMessage: 'this Space is at its theme limit',
    );
    await rig.open(tester);

    await pickFromMenu(tester, 'Publish to Space');
    expect(find.textContaining('theme limit'), findsOneWidget);
  });

  testWidgets('a failing theme is not published', (tester) async {
    final rig = EditorRig();
    await rig.open(tester, seed: ThemeEditorSeed(failingDocument()));

    await pickFromMenu(tester, 'Publish to Space');
    expect(rig.calls.where((c) => c.startsWith('POST')), isEmpty);
    expect(find.text('Fix the failing contrast checks first.'), findsOneWidget);
  });

  testWidgets('export writes the theme file and it reads back', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);

    await _rename(tester, 'Dusk Rose');
    await pickFromMenu(tester, 'Export to file');

    final (name, bytes) = rig.saved.single;
    expect(name, 'dusk-rose.slimm-theme.json');
    final parsed = parseThemeFile(utf8.decode(bytes));
    expect(parsed.problems, isEmpty);
    expect(parsed.document!.name, 'Dusk Rose');
    expect(rig.toasts, ['Exported dusk-rose.slimm-theme.json.']);
  });

  testWidgets('delete asks, removes the saved theme and goes back to Themes', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    await _rename(tester, 'Gone soon');
    await tapIn(tester, byKey('theme-editor-save'));
    expect(rig.container.read(myThemesProvider), hasLength(1));

    await pickFromMenu(tester, 'Delete');
    expect(find.text('Delete Gone soon?'), findsOneWidget);
    expect(rig.container.read(myThemesProvider), hasLength(1));
    await tapIn(tester, find.text('Delete'));

    expect(rig.container.read(myThemesProvider), isEmpty);
    _expectThemes();
  });

  testWidgets('a delete that cannot be written says so and stays open', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    await _rename(tester, 'Stuck');
    await tapIn(tester, byKey('theme-editor-save'));
    SharedPreferencesStorePlatform.instance = _FailingStore();

    await pickFromMenu(tester, 'Delete');
    await tapIn(tester, find.text('Delete'));
    await settle(tester);

    expect(byKey('theme-editor-error'), findsOneWidget);
    expect(byKey('theme-editor-preview'), findsOneWidget);
  });

  testWidgets('Delete names the theme as saved, not the edited name', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    await _rename(tester, 'Gone soon');
    await tapIn(tester, byKey('theme-editor-save'));

    for (final edited in ['', 'Renamed, not saved']) {
      await _rename(tester, edited);
      await pickFromMenu(tester, 'Delete');
      expect(find.text('Delete Gone soon?'), findsOneWidget, reason: edited);
      await tapIn(tester, find.text('Cancel'));
    }
    expect(rig.container.read(myThemesProvider), hasLength(1));
  });

  testWidgets('at a laptop every way out asks before changes are lost', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester);
    await _rename(tester, 'Changed');
    final ways = <String, Future<void> Function()>{
      'back': () => tapIn(tester, find.byTooltip('Back to Themes')),
      'close': () => tapIn(tester, find.byTooltip('Close settings')),
      'nav': () => tapIn(tester, find.text('Other')),
      'escape': () async {
        await tapIn(tester, byKey('theme-editor-name'));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await settle(tester);
      },
      'scrim': () async {
        await tester.tapAt(const Offset(20, 20));
        await settle(tester);
      },
      'system back': () async {
        await tester.binding.handlePopRoute();
        await settle(tester);
      },
      'search': () async {
        await tester.enterText(byKey('settings-search'), 'Other setting');
        await settle(tester);
        await tapIn(
          tester,
          find.byKey(const ValueKey('settings-result-other-Other setting')),
        );
      },
    };
    for (final MapEntry(key: way, value: leave) in ways.entries) {
      await leave();
      _expectAsked(way);
      await _keepEditing(tester, way);
    }

    await tapIn(tester, find.byTooltip('Back to Themes'));
    await tapIn(tester, byKey('theme-editor-confirm'));
    _expectThemes();
  });

  testWidgets('on a phone back and system back ask before changes are lost', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);
    await _rename(tester, 'Changed');

    await tapIn(tester, find.byTooltip('Back to Themes'));
    _expectAsked('back');
    await _keepEditing(tester, 'back');
    await tester.binding.handlePopRoute();
    await settle(tester);
    _expectAsked('system back');
    await tapIn(tester, byKey('theme-editor-confirm'));
    expect(byKey('theme-editor-preview'), findsNothing);
  });

  testWidgets('a clean editor leaves without asking', (tester) async {
    final rig = EditorRig();
    await rig.open(tester);

    await tapIn(tester, find.byTooltip('Back to Themes'));
    expect(byKey('theme-editor-confirm'), findsNothing);
    _expectThemes();

    await tapIn(tester, find.byTooltip('Close settings'));
    expect(find.text('channel'), findsOneWidget);
  });

  testWidgets('on a phone a colour opens a titled sheet and Cancel reverts', (
    tester,
  ) async {
    final rig = EditorRig();
    await rig.open(tester, size: phone);
    final before = themeBases['dark']!.accent;

    await tapIn(tester, byKey('theme-main-accent'));
    expect(find.widgetWithText(AppSheetHeader, 'Accent'), findsOneWidget);
    expect(
      find.text(
        'Also sets Accent fill, Accent ring and Focus ring until you change '
        'them.',
      ),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(AppColourPicker.hexFieldKey), '#FFB000');
    await tester.pump();
    final link = tester.widget<Text>(find.text('Link to the build'));
    expect(link.style!.color, const Color(0xFFFFB000));

    await tapIn(tester, find.text('Cancel'));
    final after = tester.widget<Text>(find.text('Link to the build'));
    expect(after.style!.color, before);
    expect(saveEnabled(tester), isTrue);
  });
}
