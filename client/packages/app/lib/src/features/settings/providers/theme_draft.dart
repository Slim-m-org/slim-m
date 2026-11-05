// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme being edited: its colours, the contrast floors they must clear,
/// and whether anything changed since it was last saved.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:slimm_design_system/design_system.dart';

/// A theme to open the editor on, and the "Mine" entry it replaces when saved.
class ThemeEditorSeed {
  const ThemeEditorSeed(this.document, {this.mineId});

  final ThemeDocument document;
  final String? mineId;

  /// A new theme that starts as a copy of a built-in preset.
  factory ThemeEditorSeed.fromBase(String base) => ThemeEditorSeed(
    ThemeDocument.of(
      themeBases[base]!,
      name: 'My theme',
      author: '',
      base: base,
      brightness: base == 'light' ? Brightness.light : Brightness.dark,
    ),
  );
}

class ThemeDraft extends ChangeNotifier {
  ThemeDraft(ThemeEditorSeed seed)
    : _document = seed.document,
      _saved = seed.document.toJsonText(),
      mineId = seed.mineId;

  ThemeDocument _document;
  String _saved;

  /// The "Mine" entry this saves over; null until the first save of a new theme.
  String? mineId;

  ThemeDocument get document => _document;

  List<ThemeContrastCheck> get checks => themeContrastChecks(_document.colours);

  List<ThemeContrastCheck> get failing => [
    for (final c in checks)
      if (!c.passes) c,
  ];

  bool get nameValid {
    final length = _document.name.trim().runes.length;
    return length >= 1 && length <= themeNameMaxChars;
  }

  bool get canSave => nameValid && failing.isEmpty;

  bool get dirty => _document.toJsonText() != _saved;

  /// The file text as last saved, to tell whether the theme in use is this one.
  String get savedText => _saved;

  void setName(String name) => _replace(_document.copyWith(name: name));

  void setBrightness(Brightness brightness) =>
      _replace(_document.copyWith(brightness: brightness));

  /// Keeps the token's own opacity: the picker chooses a hue, not an alpha.
  void setColour(String token, Color colour) {
    final alpha = themeAlphaTokens.contains(token)
        ? _document.colours[token]!.a
        : 1.0;
    _setToken(token, colour.withValues(alpha: alpha));
  }

  void setOpacity(String token, double opacity) => _setToken(
    token,
    _document.colours[token]!.withValues(alpha: opacity.clamp(0.0, 1.0)),
  );

  /// Replaces the colours, mode and preset with [other]'s, keeping this name.
  void startFrom(ThemeDocument other) =>
      _replace(other.copyWith(name: _document.name, author: _document.author));

  void applyFix(ThemeContrastCheck check) {
    final fixed = check.fix(_document.colours);
    if (fixed != null) _setToken(check.fg, fixed);
  }

  /// Applies the suggested change for every failing floor.
  void applyAllFixes() {
    for (final check in failing) {
      final fixed = check.fix(_document.colours);
      if (fixed != null) _setToken(check.fg, fixed);
    }
  }

  void markSaved(String id) {
    mineId = id;
    _saved = _document.toJsonText();
    notifyListeners();
  }

  void _setToken(String token, Color colour) => _replace(
    _document.copyWith(colours: {..._document.colours, token: colour}),
  );

  void _replace(ThemeDocument next) {
    _document = next;
    notifyListeners();
  }
}
