// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// Linked colours in the theme editor: a colour follows its main colour by the
/// same HSL change until it is edited itself. Links live only while the editor
/// is open; a theme file never holds them (decision 0106 refuses unknown keys).
library;

import 'package:flutter/painting.dart';
import 'package:slimm_design_system/design_system.dart' show themeTokenLabels;

import '../../../permissions.dart' show joinLabels;

/// Each main colour and the colours that follow it.
const themeLinkedColours = <String, List<String>>{
  'accent': ['accentFill', 'accentRing', 'focusRing'],
  'surfaceBase': ['surfaceSunken', 'surfaceRaised'],
  'textPrimary': ['textSecondary', 'textDisabled'],
  'warnText': ['warnSoft'],
};

/// How a main colour is named where a follower says what it follows.
const themeMainColourLabels = {
  'surfaceBase': 'Background',
  'accent': 'Accent',
  'textPrimary': 'Text',
  'warnText': 'Warning text',
};

/// The main colour [token] follows while linked, or null for one that never does.
String? themeLinkParentOf(String token) {
  for (final MapEntry(key: parent, value: children)
      in themeLinkedColours.entries) {
    if (children.contains(token)) return parent;
  }
  return null;
}

typedef _Anchor = ({Color parent, Color child});

/// Which colours still follow their main colour, and where each pair stood when
/// the link was made, so dragging a main colour back restores its followers.
class ThemeLinks {
  /// Every link on, anchored at [colours].
  factory ThemeLinks.start(Map<String, Color> colours) => ThemeLinks._({
    for (final MapEntry(key: parent, value: children)
        in themeLinkedColours.entries)
      for (final child in children)
        child: (parent: colours[parent]!, child: colours[child]!),
  });

  const ThemeLinks._(this._anchors);

  final Map<String, _Anchor> _anchors;

  bool isLinked(String token) => _anchors.containsKey(token);

  /// The colours still following [parent], in the order they are listed.
  List<String> followers(String parent) => [
    for (final child in themeLinkedColours[parent] ?? const <String>[])
      if (_anchors.containsKey(child)) child,
  ];

  /// The same links with only [token]'s own broken.
  ThemeLinks unlink(String token) {
    if (!isLinked(token)) return this;
    return ThemeLinks._({..._anchors}..remove(token));
  }

  /// [colours] with [parent] set to [colour] and each follower moved by the
  /// same HSL change from its anchor, keeping the follower's own opacity.
  Map<String, Color> follow(
    Map<String, Color> colours,
    String parent,
    Color colour,
  ) => {
    ...colours,
    parent: colour,
    for (final child in followers(parent))
      child: _shifted(
        _anchors[child]!,
        colour,
      ).withValues(alpha: colours[child]!.a),
  };
}

Color _shifted(_Anchor anchor, Color parent) {
  if (parent.toARGB32() == anchor.parent.toARGB32()) return anchor.child;
  final from = HSLColor.fromColor(anchor.parent);
  final to = HSLColor.fromColor(parent);
  final child = HSLColor.fromColor(anchor.child);
  return HSLColor.fromAHSL(
    1,
    (child.hue + to.hue - from.hue) % 360,
    (child.saturation + to.saturation - from.saturation).clamp(0.0, 1.0),
    (child.lightness + to.lightness - from.lightness).clamp(0.0, 1.0),
  ).toColor();
}

/// What changing [token] also changes, for the picker's caption, or null.
String? themeLinkNote(ThemeLinks links, String token) {
  if (themeLinkedColours.containsKey(token)) {
    final followers = links.followers(token);
    if (followers.isEmpty) return null;
    final names = [for (final f in followers) themeTokenLabels[f]!];
    final them = followers.length == 1 ? 'it' : 'them';
    return 'Also sets ${joinLabels(names)} until you change $them.';
  }
  final parent = themeLinkParentOf(token);
  if (parent == null || !links.isLinked(token)) return null;
  return 'Follows ${themeMainColourLabels[parent]} until you change it.';
}
