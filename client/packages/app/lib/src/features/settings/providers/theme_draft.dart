// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
/// The theme being edited: its colours and the links between them, the
/// contrast floors they must clear, and whether anything changed since it
/// was last saved.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:slimm_design_system/design_system.dart';

import 'theme_links.dart';

/// A theme to open the editor on, and the "Mine" entry it replaces when saved.
class ThemeEditorSeed {
  const ThemeEditorSeed(this.document, {this.mineId, this.startedFrom});

  final ThemeDocument document;
  final String? mineId;

  /// The Start from choice it came from (`base:dark`, `mine:<id>`,
  /// `space:<id>`); its own preset when null.
  final String? startedFrom;

  /// A new theme that starts as a copy of a built-in preset.
  factory ThemeEditorSeed.fromBase(String base) => ThemeEditorSeed(
    ThemeDocument.of(
      themeBases[base]!,
      name: 'My theme',
      author: '',
      base: base,
      brightness: base == 'light' ? Brightness.light : Brightness.dark,
    ),
    startedFrom: 'base:$base',
  );
}

/// Where a draft stood, to go back to when a colour pick is cancelled.
typedef ThemeDraftMark = ({ThemeDocument document, ThemeLinks links});

/// Enough rounds for a fix that moves a main colour to settle its followers too.
const _fixRounds = 24;

class ThemeDraft extends ChangeNotifier {
  ThemeDraft(ThemeEditorSeed seed)
    : _document = seed.document,
      _saved = seed.document.toJsonText(),
      _savedName = seed.document.name.trim(),
      _links = ThemeLinks.start(seed.document.colours),
      _startedFrom = seed.startedFrom ?? 'base:${seed.document.base}',
      mineId = seed.mineId;

  ThemeDocument _document;
  String _saved;
  String _savedName;
  ThemeLinks _links;
  String _startedFrom;

  ThemeLinks get links => _links;

  /// The Start from choice the colours came from.
  String get startedFrom => _startedFrom;

  /// The "Mine" entry this saves over; null until the first save of a new theme.
  String? mineId;

  ThemeDocument get document => _document;

  List<ThemeContrastCheck>? _checks;

  List<ThemeContrastCheck> get checks =>
      _checks ??= themeContrastChecks(_document.colours);

  List<ThemeContrastCheck> get failing => [
    for (final c in checks)
      if (!c.passes) c,
  ];

  /// The colours a failing check asks to change, so a warning sits on them alone.
  Set<String> get failingColours => {for (final c in failing) c.fg};

  bool get nameValid {
    final length = _document.name.trim().runes.length;
    return length >= 1 && length <= themeNameMaxChars;
  }

  bool get canSave => nameValid && failing.isEmpty;

  bool get dirty => _document.toJsonText() != _saved;

  /// The file text as last saved, to tell whether the theme in use is this one.
  String get savedText => _saved;

  /// The name as last saved, which is what Mine shows while the field is edited.
  String get savedName => _savedName;

  void setName(String name) => _replace(_document.copyWith(name: name));

  void setBrightness(Brightness brightness) =>
      _replace(_document.copyWith(brightness: brightness));

  /// Keeps the token's own opacity: the picker chooses a hue, not an alpha.
  /// A main colour moves its followers; any other colour leaves its link.
  void setColour(String token, Color colour) {
    final alpha = themeAlphaTokens.contains(token)
        ? _document.colours[token]!.a
        : 1.0;
    final value = colour.withValues(alpha: alpha);
    if (themeLinkedColours.containsKey(token)) {
      _setColours(_links.follow(_document.colours, token, value));
      return;
    }
    _links = _links.unlink(token);
    _setToken(token, value);
  }

  void setOpacity(String token, double opacity) => _setToken(
    token,
    _document.colours[token]!.withValues(alpha: opacity.clamp(0.0, 1.0)),
  );

  /// Replaces the colours, mode and preset with [other]'s, keeping this name,
  /// and turns every link back on. [key] names the choice; its preset when null.
  void startFrom(ThemeDocument other, {String? key}) {
    _startedFrom = key ?? 'base:${other.base}';
    _links = ThemeLinks.start(other.colours);
    _replace(other.copyWith(name: _document.name, author: _document.author));
  }

  /// Changes the check's colour the least that passes it, moving any followers.
  void applyFix(ThemeContrastCheck check) {
    final fixed = check.fix(_document.colours);
    if (fixed != null) setColour(check.fg, fixed);
  }

  /// Fixes every failing check on [token], worst first, until none is left.
  void fixColour(String token) => _fixWhile((c) => c.fg == token);

  /// Applies the suggested change for every failing floor.
  void applyAllFixes() => _fixWhile((_) => true);

  void _fixWhile(bool Function(ThemeContrastCheck) which) {
    for (var round = 0; round < _fixRounds; round++) {
      final left = [
        for (final c in failing)
          if (which(c)) c,
      ];
      if (left.isEmpty) return;
      applyFix(
        left.reduce((a, b) => b.ratio / b.min < a.ratio / a.min ? b : a),
      );
    }
  }

  ThemeDraftMark mark() => (document: _document, links: _links);

  void restore(ThemeDraftMark mark) {
    _links = mark.links;
    _replace(mark.document);
  }

  void markSaved(String id) {
    mineId = id;
    _saved = _document.toJsonText();
    _savedName = _document.name.trim();
    notifyListeners();
  }

  void _setToken(String token, Color colour) =>
      _setColours({..._document.colours, token: colour});

  void _setColours(Map<String, Color> colours) =>
      _replace(_document.copyWith(colours: colours));

  void _replace(ThemeDocument next) {
    _document = next;
    _checks = null;
    notifyListeners();
  }
}
