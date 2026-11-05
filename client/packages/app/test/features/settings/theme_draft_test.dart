// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The draft the editor works on: edits, the save gate and the fixes.
library;

import 'dart:ui' show Brightness, Color;

import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDraft _draft([String base = 'dark']) =>
    ThemeDraft(ThemeEditorSeed.fromBase(base));

void main() {
  test('a copy of a built-in is valid and clean', () {
    for (final base in themeBases.keys) {
      final draft = _draft(base);
      expect(draft.canSave, isTrue, reason: base);
      expect(draft.dirty, isFalse);
    }
  });

  test('an edit makes it dirty and marking it saved cleans it', () {
    final draft = _draft()..setName('Dusk');
    expect(draft.dirty, isTrue);
    draft.markSaved('id-1');
    expect(draft.dirty, isFalse);
    expect(draft.mineId, 'id-1');
  });

  test('a colour pick keeps an opacity token translucent', () {
    final draft = _draft();
    final before = draft.document.colours['accentRing']!;
    expect(before.a, lessThan(1));
    draft.setColour('accentRing', const Color(0xFF00FF00));
    expect(draft.document.colours['accentRing']!.a, before.a);
    draft.setColour('accent', const Color(0x80FF0000));
    expect(draft.document.colours['accent']!.a, 1);
  });

  test('opacity moves only alpha', () {
    final draft = _draft()..setOpacity('stripe', 0.25);
    expect(draft.document.colours['stripe']!.a, closeTo(0.25, 0.01));
    expect(
      draft.document.colours['stripe']!.toARGB32() & 0xFFFFFF,
      themeBases['dark']!.stripe.toARGB32() & 0xFFFFFF,
    );
  });

  test('failing contrast blocks saving until fixed', () {
    final draft = _draft()
      ..setColour('textPrimary', themeBases['dark']!.surfaceBase);
    expect(draft.failing, isNotEmpty);
    expect(draft.canSave, isFalse);
    draft.applyAllFixes();
    expect(draft.canSave, isTrue);
  });

  test('a name must have 1 to 40 characters', () {
    final draft = _draft();
    draft.setName('  ');
    expect(draft.nameValid, isFalse);
    expect(draft.canSave, isFalse);
    draft.setName('a' * 41);
    expect(draft.nameValid, isFalse);
    draft.setName('a' * 40);
    expect(draft.nameValid, isTrue);
  });

  test('startFrom takes the colours and mode, not the name', () {
    final draft = _draft()..setName('Mine');
    draft.startFrom(ThemeEditorSeed.fromBase('light').document);
    expect(draft.document.name, 'Mine');
    expect(draft.document.base, 'light');
    expect(draft.document.brightness, Brightness.light);
    expect(
      draft.document.colours['surfaceBase'],
      themeBases['light']!.surfaceBase,
    );
  });

  test('a saved file reads back as the same theme', () {
    final draft = _draft('forest')..setName('Pine');
    final parsed = parseThemeFile(draft.document.toJsonText());
    expect(parsed.problems, isEmpty);
    expect(parsed.document!.toJson(), draft.document.toJson());
  });
}
