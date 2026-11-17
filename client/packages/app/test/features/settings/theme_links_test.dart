// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linked colours: a main colour moves its followers by the same HSL change,
/// a follower edited on its own leaves only its own link, and Start from puts
/// every link back.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slimm_app/src/features/settings/providers/theme_draft.dart';
import 'package:slimm_app/src/features/settings/providers/theme_links.dart';
import 'package:slimm_design_system/design_system.dart';

ThemeDraft _draft([String base = 'dark']) =>
    ThemeDraft(ThemeEditorSeed.fromBase(base));

HSLColor _hsl(Color c) => HSLColor.fromColor(c);

void _expectSameDelta({
  required Color parentBefore,
  required Color parentAfter,
  required Color childBefore,
  required Color childAfter,
}) {
  final p0 = _hsl(parentBefore), p1 = _hsl(parentAfter), c0 = _hsl(childBefore);
  final expected = HSLColor.fromAHSL(
    1,
    (c0.hue + p1.hue - p0.hue) % 360,
    (c0.saturation + p1.saturation - p0.saturation).clamp(0, 1),
    (c0.lightness + p1.lightness - p0.lightness).clamp(0, 1),
  ).toColor();
  for (final (a, b) in [
    (childAfter.r, expected.r),
    (childAfter.g, expected.g),
    (childAfter.b, expected.b),
  ]) {
    expect(a, closeTo(b, 1.5 / 255));
  }
  expect(childAfter.a, childBefore.a);
}

void main() {
  test('every main colour moves each follower by the same HSL change', () {
    for (final MapEntry(key: parent, value: children)
        in themeLinkedColours.entries) {
      final draft = _draft();
      final before = draft.document.colours;
      final moved = HSLColor.fromColor(before[parent]!);
      final next = moved
          .withHue((moved.hue + 40) % 360)
          .withSaturation((moved.saturation + 0.1).clamp(0, 1))
          .withLightness((moved.lightness + 0.05).clamp(0, 1))
          .toColor();
      draft.setColour(parent, next);
      final after = draft.document.colours;
      expect(after[parent], next, reason: parent);
      for (final child in children) {
        _expectSameDelta(
          parentBefore: before[parent]!,
          parentAfter: next,
          childBefore: before[child]!,
          childAfter: after[child]!,
        );
      }
    }
  });

  test('a follower keeps its own opacity while it follows', () {
    final draft = _draft();
    final ring = draft.document.colours['accentRing']!.a;
    final tint = draft.document.colours['warnSoft']!.a;
    expect(ring, lessThan(1));
    draft
      ..setColour('accent', const Color(0xFF2BB3A3))
      ..setColour('warnText', const Color(0xFFE0B040));
    expect(draft.document.colours['accentRing']!.a, ring);
    expect(draft.document.colours['warnSoft']!.a, tint);
    expect(
      draft.document.colours['accentRing']!.withValues(alpha: 1),
      const Color(0xFF2BB3A3),
    );
  });

  test('moving the opacity keeps the link', () {
    final draft = _draft()..setOpacity('accentRing', 0.5);
    expect(draft.links.isLinked('accentRing'), isTrue);
    draft.setColour('accent', const Color(0xFF2BB3A3));
    expect(draft.document.colours['accentRing']!.a, closeTo(0.5, 0.01));
  });

  test('dragging a main colour back puts its followers back', () {
    final draft = _draft();
    final before = draft.document.colours;
    draft
      ..setColour('surfaceBase', const Color(0xFFFFFFFF))
      ..setColour('surfaceBase', before['surfaceBase']!);
    expect(draft.document.colours['surfaceSunken'], before['surfaceSunken']);
    expect(draft.document.colours['surfaceRaised'], before['surfaceRaised']);
  });

  test('editing a follower breaks only its own link', () {
    final draft = _draft()..setColour('accentFill', const Color(0xFF884488));
    expect(draft.links.isLinked('accentFill'), isFalse);
    expect(draft.links.isLinked('focusRing'), isTrue);
    expect(draft.links.isLinked('accentRing'), isTrue);

    draft.setColour('accent', const Color(0xFF2BB3A3));
    expect(draft.document.colours['accentFill'], const Color(0xFF884488));
    expect(draft.document.colours['focusRing'], const Color(0xFF2BB3A3));
  });

  test('Start from turns every link back on', () {
    final draft = _draft()
      ..setColour('accentFill', const Color(0xFF884488))
      ..setColour('textDisabled', const Color(0xFF555555));
    draft.startFrom(ThemeEditorSeed.fromBase('forest').document);
    for (final child in themeLinkedColours.values.expand((c) => c)) {
      expect(draft.links.isLinked(child), isTrue, reason: child);
    }
    expect(draft.startedFrom, 'base:forest');
    draft.setColour('accent', const Color(0xFFFF7A1A));
    expect(draft.document.colours['accentFill'], const Color(0xFFFF7A1A));
  });

  test('a cancelled pick puts the links back with the colour', () {
    final draft = _draft();
    final mark = draft.mark();
    draft.setColour('focusRing', const Color(0xFF884488));
    expect(draft.links.isLinked('focusRing'), isFalse);
    draft.restore(mark);
    expect(draft.links.isLinked('focusRing'), isTrue);
    expect(draft.dirty, isFalse);
  });

  test('the note names what a colour sets or follows', () {
    final links = ThemeLinks.start(themeBases['dark']!.toColourMap());
    expect(
      themeLinkNote(links, 'accent'),
      'Also sets Accent fill, Accent ring and Focus ring until you change '
      'them.',
    );
    expect(
      themeLinkNote(links, 'warnText'),
      'Also sets Warning tint until you change it.',
    );
    expect(
      themeLinkNote(links, 'accentRing'),
      'Follows Accent until you change it.',
    );
    expect(themeLinkNote(links.unlink('accentRing'), 'accentRing'), isNull);
    expect(themeLinkNote(links, 'dangerText'), isNull);
    final none = links.unlink('warnSoft');
    expect(themeLinkNote(none, 'warnText'), isNull);
  });
}

extension on AppTokens {
  Map<String, Color> toColourMap() => ThemeDocument.of(
    this,
    name: 'x',
    author: '',
    base: 'dark',
    brightness: Brightness.dark,
  ).colours;
}
